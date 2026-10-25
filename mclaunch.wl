#!/usr/bin/env wolframscript
(* ==================================================================
   Wolfram Minecraft Launcher  ——  纯 Wolfram 语言实现
   ------------------------------------------------------------------
   直接运行进入交互菜单：改版本 / 玩家名 / 内存 / 窗口大小，
   按 5 启动，q 退出。不读命令行参数。
   ================================================================== *)

(* ---------------- 平台判定 ---------------- *)
$osName = Which[
   $OperatingSystem === "Windows", "windows",
   $OperatingSystem === "MacOSX", "osx",
   True, "linux"];
$osLabel = <|"windows" -> "Windows", "osx" -> "macOS", "linux" -> "Linux"|>[$osName];
$procType = ToLowerCase[ToString[$ProcessorType]];
$archTag = Which[
   StringContainsQ[$procType, "arm"] || StringContainsQ[$procType, "aarch"], "arm64",
   $SystemWordLength === 64, "x86_64",
   True, "x86"];
$pathSep = If[$osName === "windows", ";", ":"];
$javaExe = If[$osName === "windows", "java.exe", "java"];

envOr[name_String, fallback_] := With[{v = Environment[name]},
   If[StringQ[v] && v =!= "", v, fallback]];

$mcHome = Which[
   envOr["MCLAUNCH_GAME_DIR", ""] =!= "", envOr["MCLAUNCH_GAME_DIR", ""],
   $osName === "windows",
   FileNameJoin[{envOr["APPDATA", $HomeDirectory], ".minecraft"}],
   $osName === "osx",
   FileNameJoin[{$HomeDirectory, "Library", "Application Support", "minecraft"}],
   True, FileNameJoin[{$HomeDirectory, ".minecraft"}]];
$mcVersions  = FileNameJoin[{$mcHome, "versions"}];
$mcLibs      = FileNameJoin[{$mcHome, "libraries"}];
$mcAssets    = FileNameJoin[{$mcHome, "assets"}];
$manifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

$features = <|
   "is_demo_user" -> False,
   "has_custom_resolution" -> True,
   "has_quick_plays_support" -> False,
   "is_quick_play_singleplayer" -> False,
   "is_quick_play_multiplayer" -> False,
   "is_quick_play_realms" -> False|>;

(* ---------------- 基础工具 ---------------- *)
ensureDir[p_] := (If[!DirectoryQ[p], CreateDirectory[p, CreateIntermediateDirectories -> True]]; p);

(* Windows 没有 chmod，凭证文件靠用户的 NTFS 目录权限 *)
setPrivate[file_String] := If[$osName =!= "windows",
   Quiet@RunProcess[{"chmod", "600", file}];];

(* ExtractArchive 不能解压到已存在的目录，先解到临时目录再合并 *)
extractInto[jar_String, dir_String] := Module[{tmp, files, rel, dst},
   tmp = FileNameJoin[{$TemporaryDirectory,
      "mcl-nat-" <> IntegerString[Hash[jar], 10, 12]}];
   Quiet@Check[If[DirectoryQ[tmp], DeleteDirectory[tmp, DeleteContents -> True]], Null];
   If[Quiet@Check[ExtractArchive[jar, tmp], $Failed] === $Failed,
    Quiet@Check[DeleteDirectory[tmp, DeleteContents -> True], Null];
    Return[Null]];
   files = Quiet@Check[FileNames["*", tmp, Infinity], {}];
   Scan[Function[f,
      If[Quiet@FileType[f] === File,
       rel = StringDrop[f, StringLength[tmp] + 1];
       dst = FileNameJoin[{dir, rel}];
       ensureDir[DirectoryName[dst]];
       Quiet@CopyFile[f, dst, OverwriteTarget -> True]]], files];
   Quiet@Check[DeleteDirectory[tmp, DeleteContents -> True], Null]];

dl[url_String, file_String, size_Integer : 0] := Module[{},
   ensureDir[DirectoryName[file]];
   If[FileExistsQ[file] && (size === 0 || FileByteCount[file] === size), Return[file]];
   Quiet@Check[URLDownload[url, file, TimeConstraint -> 300], Return[$Failed]];
   If[FileExistsQ[file], file, $Failed]];

getJson[url_String] := Module[{tmp, j},
   tmp = FileNameJoin[{$TemporaryDirectory, "mcl-" <> IntegerString[Hash[url]] <> ".json"}];
   If[dl[url, tmp] === $Failed, Return[$Failed]];
   j = Quiet@Check[Import[tmp, "RawJSON"], $Failed];
   Quiet@DeleteFile[tmp];
   j];

(* ---------------- 规则判定 ---------------- *)
archMatches[a_String] := Which[
   a === "x86", $SystemWordLength === 32,
   a === "arm64" || a === "aarch64", $archTag === "arm64",
   a === "x86_64" || a === "amd64", $SystemWordLength === 64 && $archTag === "x86_64",
   True, False];

(* os.version（如 Windows 的 "^10\\."）只影响少数可选库，这里放宽处理 *)
osMatches[os_Association] := Module[{n = Lookup[os, "name", None], a = Lookup[os, "arch", None]},
   And[n === None || n === $osName, a === None || (StringQ[a] && archMatches[a])]];

featureMatches[feat_Association] := AllTrue[Normal[feat],
   Lookup[$features, #[[1]], False] === #[[2]] &];

ruleMatches[rule_Association] := Module[{os = Lookup[rule, "os", <||>],
    feat = Lookup[rule, "features", <||>]},
   osMatches[os] && featureMatches[feat]];

resolveRules[rules_List] := Module[{idx},
   If[rules === {}, Return[True]];
   idx = Select[Range[Length[rules]], ruleMatches[rules[[#]]] &];
   If[idx === {}, Return[False]];
   Lookup[rules[[Last[idx]]], "action"] === "allow"];

libAllowed[lib_Association] := Module[{rules = Lookup[lib, "rules", {}]},
   If[rules === {}, True, resolveRules[rules]]];

(* 1.12 及更早的 natives 在 downloads.classifiers 里，键名按平台取 *)
legacyNatives[lib_Association] := Module[{n, key, cls},
   n = Lookup[lib, "natives", None];
   If[! AssociationQ[n], Return[{}]];
   key = Lookup[n, $osName, None];
   If[! StringQ[key], Return[{}]];
   key = StringReplace[key,
     "$" <> "{arch}" -> If[$SystemWordLength === 64, "64", "32"]];
   cls = Lookup[Lookup[lib, "downloads", <||>], "classifiers", <||>];
   If[! AssociationQ[cls], Return[{}]];
   DeleteCases[{Lookup[cls, key, Nothing]}, _Nothing | _Missing]];

(* ---------------- 路径换算 ---------------- *)
libRelPath[name_String] := Module[{p = StringSplit[name, ":"]},
   If[Length[p] < 3, Return[$Failed]];
   FileNameJoin[Join[StringSplit[StringReplace[p[[1]], "." -> "/"], "/"],
     {p[[2]], p[[3]], p[[2]] <> "-" <> p[[3]] <> ".jar"}]]];

(* ---------------- 参数展开 ---------------- *)
expandArgs[args_List] := Flatten[Map[
    Function[a,
     Which[
      AssociationQ[a] && KeyExistsQ[a, "value"],
      If[KeyExistsQ[a, "rules"] && !resolveRules[a["rules"]], {}, Flatten[{a["value"]}]],
      StringQ[a], a,
      True, {}]],
    args]];

fillVars[str_String, vars_Association] :=
  Fold[StringReplace[#1, #2[[1]] -> #2[[2]]] &, str, Normal@vars];

(* 丢掉「flag 后面跟着空值」的整对参数，例如 --xuid "" 或 --quickPlayPath "" *)
cleanArgs[args_List] := Module[{out = {}, i = 1, n = Length[args]},
   While[i <= n,
    Which[
     StringQ[args[[i]]] && StringStartsQ[args[[i]], "--"] && i < n && args[[i + 1]] === "",
     i += 2,
     args[[i]] === "", i += 1,
     True, AppendTo[out, args[[i]]]; i += 1]];
   out];

pathDirs[] := Module[{p = envOr["PATH", ""],
   sep = If[$osName === "windows", ";", ":"]},
   DeleteCases[StringTrim[#, "\""] & /@ StringSplit[p, sep], ""]];

javaMajor[java_String] := Module[{r, first, nums, parts},
   r = Quiet@Check[RunProcess[{java, "-version"}, "StandardError"], $Failed];
   If[! StringQ[r], Return[$Failed]];
   first = First[StringSplit[r, "\n"]];
   nums = StringCases[first, RegularExpression["[0-9]+(?:\\.[0-9]+)*"]];
   If[nums === {}, Return[$Failed]];
   parts = StringSplit[First[nums], "."];
   Which[
    First[parts] === "1" && Length[parts] >= 2, ToExpression[parts[[2]]],
    True, ToExpression[First[parts]]]];

javaCandidates[] := Module[{jh, pf, lad, roots},
   jh = envOr["JAVA_HOME", ""];
   pf = envOr["ProgramFiles", ""];
   lad = envOr["LOCALAPPDATA", ""];
   roots = DeleteCases[If[$osName === "windows",
      {If[pf =!= "", FileNameJoin[{pf, #}], $Failed] & /@
        {"Java", "Eclipse Adoptium", "Microsoft", "Zulu", "Amazon Corretto",
         "BellSoft", "Semeru"},
       If[lad =!= "", FileNameJoin[{lad, "Programs", "Eclipse Adoptium"}], $Failed]},
      If[$osName === "osx",
       {"/Library/Java/JavaVirtualMachines", "/opt/homebrew/opt",
        "/usr/local/opt", "/usr/lib/jvm"},
       {"/usr/lib/jvm", "/usr/lib64/jvm", "/usr/java", "/opt"}]], $Failed];
   DeleteDuplicates@DeleteCases[Join[
      {If[jh =!= "", FileNameJoin[{jh, "bin", $javaExe}], $Failed]},
      FileNameJoin[{#, $javaExe}] & /@ pathDirs[],
      Flatten[FileNames[{"*/bin/" <> $javaExe,
         "*/Contents/Home/bin/" <> $javaExe}, #] & /@ roots]], $Failed]];

(* 返回 {路径, 主版本号}；need 为清单要求的 Java 版本 *)
pickJava[need_Integer : 0] := Module[{info, exact, higher},
   info = SortBy[DeleteCases[{#, javaMajor[#]} & /@
       Select[javaCandidates[], FileExistsQ], {_, $Failed} | {_, _Missing}],
     Last];
   If[info === {}, Return[$Failed]];
   exact = Select[info, Last[#] === need &];
   If[exact =!= {}, Return[First[exact]]];
   higher = Select[info, Last[#] > need &];
   If[higher =!= {}, Return[First[higher]]];
   Last[info]];

(* ---------------- 配置持久化 ---------------- *)
$cfgFile = FileNameJoin[{$mcHome, "wl-launcher.conf"}];
$cfgKeys = {"version", "user", "ram", "size", "jvm", "game", "account", "active", "instance"};

$defaultCfg = <|
   "version" -> Automatic, "user" -> "Steve", "ram" -> "4G",
   "size" -> "1280x720", "jvm" -> "", "game" -> "",
   "account" -> "offline", "active" -> "",
   "instance" -> "default"|>;

loadCfg[] := Module[{g, inst, f, base},
   g = readConf[$cfgFile];
   If[g === <||>, g = $defaultCfg];
   inst = Lookup[g, "instance", "default"];
   If[! StringQ[inst] || inst === "", inst = "default"];
   f = instCfgPath[inst];
   base = If[f === $cfgFile, g,
     If[FileExistsQ[f], Merge[{g, readConf[f]}, Last], g]];
   base = Merge[{KeyTake[$defaultCfg, $cfgKeys],
      KeyTake[base, $cfgKeys]}, Last];
   base["instance"] = inst;
   If[base["version"] === "", base["version"] = Automatic];
   base];

saveCfg[cfg_] := Module[{inst, def},
   inst = Lookup[cfg, "instance", "default"];
   If[! StringQ[inst] || inst === "", inst = "default"];
   If[inst === "default",
    writeConf[$cfgFile, cfg],
    def = readConf[$cfgFile];
    If[def === <||>, def = $defaultCfg];
    def["instance"] = inst;
    writeConf[$cfgFile, def];
    writeConf[instCfgPath[inst], cfg]]];
(* ---------------- \:591a\:8d26\:53f7\:5e93 ---------------- *)
(* \:6bcf\:4e2a\:8d26\:53f7\:5b58 name/uuid/token/refresh/expires\:ff0cconf \:91cc\:7684 active \:6307\:5411\:5f53\:524d\:9009\:4e2d\:7684 uuid\:3002
   \:8001\:7684 wl-launcher-token.json \:7b2c\:4e00\:6b21\:52a0\:8f7d\:65f6\:81ea\:52a8\:5e76\:5165\:3002 *)
$acctFile = FileNameJoin[{$mcHome, "wl-launcher-accounts.json"}];

loadAccounts[] := Module[{l},
   l = If[FileExistsQ[$acctFile],
     Quiet@Check[Import[$acctFile, "RawJSON"], {}], {}];
   If[! ListQ[l], l = {}];
   Select[l, AssociationQ[#] && StringQ[Lookup[#, "uuid", ""]] &&
      Lookup[#, "uuid", ""] =!= "" &]];

saveAccounts[l_] := (Export[$acctFile, l, "JSON"];
   setPrivate[$acctFile];);

upsertAccount[a_Association] := Module[{l, pos},
   l = loadAccounts[];
   pos = Position[Lookup[l, "uuid", ""], a["uuid"], {1}, 1];
   If[pos === {}, AppendTo[l, a], l[[First@First@pos]] = a];
   saveAccounts[l]];

removeAccount[uuid_] := (
   saveAccounts[Select[loadAccounts[], #["uuid"] =!= uuid &]];);

migrateTokenFile[] := Module[{a},
   If[FileExistsQ[$acctFile] || ! FileExistsQ[$tokenFile], Null,
    a = Quiet@Check[Import[$tokenFile, "RawJSON"], $Failed];
    If[AssociationQ[a] && KeyExistsQ[a, "uuid"],
     saveAccounts[{a}];
     Print["    \:5df2\:628a\:65e7\:51ed\:8bc1\:5e76\:5165\:591a\:8d26\:53f7\:5e93"]]];];

activeAccount[cfg_] := Module[{l, u, hit},
   l = loadAccounts[];
   If[l === {}, Return[$Failed]];
   u = If[StringQ[cfg["active"]], cfg["active"], ""];
   hit = Select[l, #["uuid"] === u &];
   If[hit === {}, First[l], First[hit]]];

escName[a_Association] := Module[{n, e},
   n = Lookup[a, "name", "?"];
   e = Lookup[a, "expires", 0];
   If[NumberQ[e] && e < AbsoluteTime[], n <> " (\:8fc7\:671f)", n]];

accountLabel[cfg_] := Module[{l, a},
   If[cfg["account"] =!= "microsoft",
    Return["\:79bb\:7ebf " <> cfg["user"]]];
   l = loadAccounts[];
   If[l === {}, Return["\:6b63\:7248\:ff08\:8fd8\:6ca1\:767b\:5f55\:ff09"]];
   a = activeAccount[cfg];
   If[! AssociationQ[a], Return["\:6b63\:7248 " <> ToString[Length[l]] <> " \:4e2a"]];
   " \:6b63\:7248 " <> escName[a] <> " \:00b7 " <>
    ToString[Length[l]] <> " \:4e2a"];

(* ---------------- 小工具 ---------------- *)
(* ---------------- \:591a\:5b9e\:4f8b ---------------- *)
$instRoot = FileNameJoin[{$mcHome, "instances"}];

(* default \:5b9e\:4f8b\:7684\:76ee\:5f55\:5c31\:662f ~/.minecraft \:672c\:8eab\:ff0c\:8001\:5b58\:6863\:4ecd\:7136\:53ef\:89c1 *)
instDir[inst_String] := If[inst === "default", $mcHome,
   FileNameJoin[{$instRoot, inst}]];

instCfgPath[inst_String] := If[inst === "default", $cfgFile,
   FileNameJoin[{$instRoot, inst, "launcher.conf"}]];

instanceNames[] := Module[{d},
   d = If[DirectoryQ[$instRoot],
     Quiet@Check[Select[FileNameTake /@ FileNames[$instRoot <> "/*"],
        DirectoryQ[FileNameJoin[{$instRoot, #}]] &], {}], {}];
   Prepend[DeleteCases[Sort[d], "default"], "default"]];

readConf[file_String] := Module[{lines, pairs},
   If[! FileExistsQ[file], Return[<||>]];
   lines = Select[Import[file, "Lines"],
     StringContainsQ[#, "="] && ! StringStartsQ[StringTrim[#], "#"] &];
   pairs = DeleteCases[
     Function[l, With[{q = StringSplit[l, "=", 2]},
        If[Length[q] === 2, StringTrim[q[[1]]] -> StringTrim[q[[2]]],
         Missing["x"]]]] /@ lines, _Missing];
   Association[pairs]];

writeConf[file_String, cfg_Association] := Module[{lines},
   ensureDir[DirectoryName[file]];
   lines = Function[k, k <> "=" <> Replace[Lookup[cfg, k, ""], Automatic -> ""]] /@ $cfgKeys;
   Export[file, StringRiffle[lines, "\n"] <> "\n", "Text"]];

gameDirOf[cfg_Association] := instDir[Lookup[cfg, "instance", "default"]];

switchTo[name_String] := Module[{def},
   def = readConf[$cfgFile];
   If[def === <||>, def = $defaultCfg];
   def["instance"] = name;
   writeConf[$cfgFile, def]];

makeInstance[name_String, cfg_Association] := Module[{new},
   ensureDir[instDir[name]];
   new = Join[cfg, <|"instance" -> name|>];
   new];

deleteInstance[name_String] := (
   If[name === "default", Return[False]];
   If[DirectoryQ[instDir[name]],
    Quiet@Check[DeleteDirectory[instDir[name], DeleteContents -> True], Null]];
   True);

instMenu[cfg0_Association] := Module[{c, cfg = cfg0, ns, i, name, victim},
   While[True,
    ns = instanceNames[];
    Print[""];
    Print["  ", "\:5b9e\:4f8b\:7ba1\:7406", "  (\:5f53\:524d: ", cfg["instance"], ")"];
    Print["  --------------------------------------------"];
    Scan[Function[n,
       Print["   ", If[n === cfg["instance"], "*", " "], " ", n]],
      ns];
    Print["  --------------------------------------------"];
    Print["  1) ", "\:5207\:6362", "   2) ", "\:65b0\:5efa", "   3) ", "\:5220\:9664", "   0) ", "\:8fd4\:56de"];
    c = askLine["  \:9009\:62e9 > "];
    If[c === $Failed, Return[cfg]];
    Switch[c,
     "1",
      i = askLine["  \:5207\:6362\:5230\:54ea\:4e2a > "];
      If[StringQ[i] && MemberQ[ns, StringTrim[i]] &&
         StringTrim[i] =!= cfg["instance"],
       saveCfg[cfg];
       switchTo[StringTrim[i]];
       cfg = loadCfg[];
       Print["  ==> ", "\:5df2\:5207\:5230\:5b9e\:4f8b ", cfg["instance"]],
       Print["  \:6ca1\:6709\:8fd9\:4e2a\:5b9e\:4f8b\:ff0c\:6216\:5df2\:7ecf\:662f\:5f53\:524d\:5b9e\:4f8b"]],
     "2",
      name = askLine["  \:65b0\:5b9e\:4f8b\:540d > "];
      If[StringQ[name] && StringTrim[name] =!= "" &&
         ! MemberQ[ns, StringTrim[name]],
       name = StringTrim[name];
       cfg = makeInstance[name, cfg];
       saveCfg[cfg];
       Print["  ==> ", "\:5df2\:521b\:5efa\:5b9e\:4f8b ", name],
       Print["  \:540d\:5b57\:4e3a\:7a7a\:6216\:5df2\:5b58\:5728"]],
     "3",
      victim = askLine["  \:5220\:9664\:54ea\:4e2a > "];
      If[StringQ[victim] && MemberQ[ns, StringTrim[victim]],
       victim = StringTrim[victim];
       If[victim === "default",
        Print["  default \:5b9e\:4f8b\:4e0d\:80fd\:5220\:9664"],
        Print["  \:786e\:5b9a\:5220\:9664 ", victim, " \:5417\:ff1f\:8f93\:5165 yes \:786e\:8ba4 > "];
        If[askLine["  > "] === "yes",
         deleteInstance[victim];
         If[cfg["instance"] === victim,
          switchTo["default"]; cfg = loadCfg[]];
         Print["  ==> ", "\:5df2\:5220\:9664 ", victim],
         Print["  \:5df2\:53d6\:6d88"]]],
       Print["  \:6ca1\:6709\:8fd9\:4e2a\:5b9e\:4f8b"]],
     "0" | "", Return[cfg],
     _, Print["  ? ", "\:6ca1\:6709\:8fd9\:4e2a\:9009\:9879"]]];
   cfg];

localVersions[] := Module[{names},
   If[! DirectoryQ[$mcVersions], Return[{}]];
   names = FileNameTake /@ Quiet@Check[FileNames[$mcVersions <> "/*"], {}];
   Sort[Select[names,
     FileExistsQ[FileNameJoin[{$mcVersions, #, # <> ".json"}]] &]]];

dirBytes[dir_String] := Module[{files},
   If[! DirectoryQ[dir], Return[0]];
   files = Quiet@Check[FileNames["*", dir, Infinity], {}];
   Total[Quiet@Check[FileByteCount[#], 0] & /@
     Select[files, Quiet@FileType[#] === File &]]];

humanBytes[b_?NumberQ] := Which[
   b >= 1073741824, ToString@Round[b/1073741824., .01] <> " GB",
   b >= 1048576, ToString@Round[b/1048576., .1] <> " MB",
   b >= 1024, ToString@Round[b/1024., .1] <> " KB",
   True, ToString[b] <> " B"];

extraArgs[s_String] := If[StringTrim[s] === "", {},
   StringSplit[StringTrim[s], WhitespaceCharacter ..]];

showProg[label_String, done_Integer, total_Integer] :=
   If[Environment["TERM"] === "",
    If[Mod[done, 20] === 0, Print["    ", label, "  ", done, " / ", total]],
    WriteString[$Output, "\r    ", label, "  ", done, " / ", total,
     "  ", Round[100. done/Max[total, 1]], "%    "]];

endProg[] := If[Environment["TERM"] =!= "", WriteString[$Output, "\n"]];

printVersions[] := Module[{m, v},
   m = getJson[$manifestUrl];
   If[m === $Failed, Print["  [x] \:62ff\:4e0d\:5230\:7248\:672c\:6e05\:5355\:ff0c\:68c0\:67e5\:7f51\:7edc"]; Return[Null]];
   v = Select[m["versions"], #["type"] === "release" &];
   Print["  \:6700\:8fd1 15 \:4e2a\:6b63\:5f0f\:7248\:ff1a"];
   Scan[Print["    ", #["id"], "    ", StringTake[#["releaseTime"], 10]] &,
    Take[v, UpTo[15]]]];

clearScreen[] := WriteString[$Output,
   FromCharacterCode[27] <> "[2J" <> FromCharacterCode[27] <> "[H"];

printMenu[cfg_] := (
   If[Environment["TERM"] =!= "", clearScreen[]];
   Print[""];
   Print["=============================================="];
   Print["        Wolfram Minecraft Launcher"];
   Print["=============================================="];
   Print["  1) \:7248\:672c        ",
    If[cfg["version"] === Automatic, "\:6700\:65b0\:6b63\:5f0f\:7248", cfg["version"]]];
   Print["  2) \:73a9\:5bb6\:540d      ", cfg["user"]];
   Print["  3) \:5185\:5b58        ", cfg["ram"]];
   Print["  4) \:7a97\:53e3        ", cfg["size"]];
   Print["  5) JVM \:53c2\:6570    ", If[cfg["jvm"] === "", "\:ff08\:65e0\:ff09", cfg["jvm"]]];
   Print["  6) \:6e38\:620f\:53c2\:6570    ", If[cfg["game"] === "", "\:ff08\:65e0\:ff09", cfg["game"]]];
   Print["  --------------------------------------------"];
   Print["  7) \:8d26\:53f7        ", accountLabel[cfg]];
   Print["  8) \:672c\:5730\:7248\:672c    ", Length[localVersions[]], " \:4e2a\:5df2\:5b89\:88c5"];
   Print["  9) \:4e0b\:8f7d\:7248\:672c    \:88c5\:4e00\:4e2a\:65b0\:7684"];
   Print["  a) \:5b89\:88c5\:52a0\:8f7d\:5668   Fabric / Forge / NeoForge"];
   Print["  m) \:6a21\:7ec4        ", Length[listMods[cfg]], " \:4e2a\:ff08", loaderName[loaderOf[cfg["version"]]], "\:ff09"];
   Print["  i) \:6e38\:620f\:76ee\:5f55    ", cfg["instance"], "  ", gameDirOf[cfg]];
   Print["  r) \:8d44\:6e90\:4e0b\:8f7d    \:8d44\:6e90\:5305\:ff08Modrinth\:ff09"];
   Print["  d) \:78c1\:76d8\:5360\:7528"];
   Print["  --------------------------------------------"];
   Print["  s) \:542f\:52a8\:6e38\:620f"];
   Print["  q) \:9000\:51fa"];
   Print["----------------------------------------------"]);

askLine[prompt_] := Module[{s},
   s = InputString[prompt];
   If[s === EndOfFile, $Failed, StringTrim[s]]];

editCfg[cfg_Association, key_String] := Module[{c, new = cfg},
   Switch[key,
    "version",
     Print["  \:8f93\:7248\:672c\:53f7\:ff1b\:56de\:8f66 = \:6700\:65b0\:6b63\:5f0f\:7248\:ff1b? = \:8054\:7f51\:5217\:7248\:672c\:ff1b@ = \:5217\:5df2\:88c5\:7684"];
     c = askLine["  \:7248\:672c > "],
    "user", c = askLine["  \:73a9\:5bb6\:540d > "],
    "ram", c = askLine["  \:5185\:5b58\:ff0c\:5982 4G \:6216 6G > "],
    "size", c = askLine["  \:5206\:8fa8\:7387\:ff0c\:5982 1280x720 > "],
    "jvm", c = askLine["  \:8ffd\:52a0 JVM \:53c2\:6570\:ff0c\:5982 -XX:+UseZGC\:ff08\:7559\:7a7a\:6e05\:9664\:ff09> "],
    "game", c = askLine["  \:8ffd\:52a0\:6e38\:620f\:53c2\:6570\:ff08\:7559\:7a7a\:6e05\:9664\:ff09> "]];
   If[c === $Failed, Return[cfg]];
   Switch[key,
    "version",
     Which[c === "", new["version"] = Automatic,
      c === "?", printVersions[],
      c === "@", printLocal[],
      True, new["version"] = c],
    "user", If[c =!= "", new["user"] = c],
    "ram", If[c =!= "", new["ram"] = If[StringMatchQ[c, DigitCharacter ..],
       c <> "G", StringReplace[c, "g" -> "G"]]],
    "size", If[c =!= "", new["size"] = c],
    "jvm", new["jvm"] = c,
    "game", new["game"] = c];
   saveCfg[new];
   new];

printLocal[] := Module[{vs = localVersions[]},
   If[vs === {}, Print["  \:672c\:5730\:8fd8\:6ca1\:88c5\:8fc7\:7248\:672c"],
    Scan[Print["    ", #] &, vs]]];

pickLocal[cfg_Association] := Module[{vs = localVersions[], c, new = cfg},
   If[vs === {}, Print["  \:672c\:5730\:8fd8\:6ca1\:88c5\:8fc7\:7248\:672c"]; Return[cfg]];
   Print["  \:5df2\:5b89\:88c5\:ff1a"];
   Scan[Print["    ", #] &, vs];
   c = askLine["  \:9009\:4e00\:4e2a\:ff08\:56de\:8f66\:8df3\:8fc7\:ff09> "];
   If[! StringQ[c] || StringTrim[c] === "", Return[cfg]];
   c = StringTrim[c];
   If[MemberQ[vs, c],
    new["version"] = c; saveCfg[new]; new,
    Print["  \:6ca1\:6709\:8fd9\:4e2a\:7248\:672c\:ff1a", c]; cfg]];

printDisk[] := Module[{a, b, c},
   Print["  \:6b63\:5728\:7edf\:8ba1\:76ee\:5f55\:5927\:5c0f\:ff0c\:7a0d\:7b49\:4e00\:4e0b\:2026"];
   a = dirBytes[FileNameJoin[{$mcHome, "libraries"}]];
   b = dirBytes[FileNameJoin[{$mcHome, "assets"}]];
   c = dirBytes[FileNameJoin[{$mcHome, "versions"}]];
   Print["    libraries   ", humanBytes[a]];
   Print["    assets      ", humanBytes[b]];
   Print["    versions    ", humanBytes[c]];
   Print["    ------------"];
   Print["    \:5408\:8ba1        ", humanBytes[a + b + c]]];

interactive[] := Module[{cfg, s, t0, r, ready, a2},
   cfg = loadCfg[];
   migrateTokenFile[];
   If[cfg["account"] =!= "microsoft",
    $auth = <|"name" -> cfg["user"],
      "uuid" -> "00000000000000000000000000000000",
      "token" -> "0", "type" -> "legacy"|>];
   While[True,
    printMenu[cfg];
    s = askLine["\:9009\:62e9 > "];
    If[s === $Failed,
     Print["[x] \:6ca1\:8bfb\:5230\:8f93\:5165\:ff08stdin \:4e0d\:662f\:7ec8\:7aef\:ff1f\:ff09"];
     Return[$Failed]];
    Switch[s,
     "1", cfg = pickVersion[cfg],
     "2", cfg = editCfg[cfg, "user"],
     "3", cfg = editCfg[cfg, "ram"],
     "4", cfg = editCfg[cfg, "size"],
     "5", cfg = editCfg[cfg, "jvm"],
     "6", cfg = editCfg[cfg, "game"],
     "7", cfg = acctMenu[cfg],
     "8", cfg = pickLocal[cfg],
     "9", downloadAsk[cfg],
     "m" | "M", cfg = modMenu[cfg],
     "i" | "I", cfg = instMenu[cfg],
     "r" | "R", cfg = resDownload[cfg],
     "a" | "A", cfg = installLoader[cfg],
     "d" | "D", printDisk[],
     "s" | "S",
      ready = True;
      If[cfg["account"] === "microsoft",
       a2 = ensureAuth[cfg];
       If[AssociationQ[a2], $auth = a2,
        Print["[x] \:6b63\:7248\:51ed\:8bc1\:65e0\:6548\:ff0c\:5148\:6309 7 \:91cd\:65b0\:767b\:5f55"]; ready = False]];
      If[ready,
       t0 = AbsoluteTime[];
       r = run[cfg];
       Print["==> \:603b\:8017\:65f6 ", Round[AbsoluteTime[] - t0, 0.1], " \:79d2"];
       Return[r]],
     "q" | "Q", Return[Null],
     "", Null,
     _, Print["  ? \:6ca1\:6709\:8fd9\:4e2a\:9009\:9879\:ff1a", s]];
    saveCfg[cfg]]];
(* ---------------- 正版登录 ---------------- *)
(* client_id 用的是 Prism Launcher*)
$clientId = "c36a9fb6-4f2a-41ff-90bd-ae7cc92031eb";
$authBase = "https://login.microsoftonline.com/consumers/oauth2/v2.0";
$tokenFile = FileNameJoin[{$mcHome, "wl-launcher-token.json"}];
$auth = <|"name" -> "Steve", "uuid" -> "00000000000000000000000000000000",
   "token" -> "0", "type" -> "legacy"|>;

postForm[url_, body_] := Module[{r},
   r = Quiet@Check[TimeConstrained[
      URLRead[HTTPRequest[url, <|"Method" -> "POST", "Body" -> body,
         "ContentType" -> "application/x-www-form-urlencoded"|>]], 40, $Failed],
     $Failed];
   If[Head[r] =!= HTTPResponse, Return[$Failed]];
   Quiet@Check[ImportString[r["Body"], "RawJSON"], $Failed]];

postJson[url_, json_, token_] := Module[{req, r},
   req = If[StringQ[token] && token =!= "",
     HTTPRequest[url, <|"Method" -> "POST",
       "Body" -> ExportString[json, "JSON"],
       "ContentType" -> "application/json",
       "Headers" -> {"Authorization" -> "Bearer " <> token}|>],
     HTTPRequest[url, <|"Method" -> "POST",
       "Body" -> ExportString[json, "JSON"],
       "ContentType" -> "application/json"|>]];
   r = Quiet@Check[TimeConstrained[URLRead[req], 40, $Failed], $Failed];
   If[Head[r] =!= HTTPResponse, Return[$Failed]];
   Quiet@Check[ImportString[r["Body"], "RawJSON"], $Failed]];

getJsonAuth[url_, token_] := Module[{r},
   r = Quiet@Check[TimeConstrained[
      URLRead[HTTPRequest[url,
        <|"Headers" -> {"Authorization" -> "Bearer " <> token}|>]], 40, $Failed],
     $Failed];
   If[Head[r] =!= HTTPResponse, Return[$Failed]];
   Quiet@Check[ImportString[r["Body"], "RawJSON"], $Failed]];

(* 微软 token -> Xbox Live -> XSTS -> Minecraft，返回登录结果 *)
mcChain[msToken_, refresh_] := Module[{xbl, xsts, mc, prof, uhs, err},
   xbl = postJson["https://user.auth.xboxlive.com/user/authenticate",
     <|"Properties" -> <|"AuthMethod" -> "RPS",
        "SiteName" -> "user.auth.xboxlive.com",
        "RpsTicket" -> "d=" <> msToken|>,
       "RelyingParty" -> "http://auth.xboxlive.com",
       "TokenType" -> "JWT"|>, ""];
   If[! AssociationQ[xbl] || ! KeyExistsQ[xbl, "Token"],
    Print["[x] Xbox Live \:8ba4\:8bc1\:5931\:8d25"]; Return[$Failed]];

   xsts = postJson["https://xsts.auth.xboxlive.com/xsts/authorize",
     <|"Properties" -> <|"SandboxId" -> "RETAIL",
        "UserTokens" -> {xbl["Token"]}|>,
       "RelyingParty" -> "rp://api.minecraftservices.com/",
       "TokenType" -> "JWT"|>, ""];
   If[! AssociationQ[xsts] || ! KeyExistsQ[xsts, "Token"],
    err = If[AssociationQ[xsts], Lookup[xsts, "XErr", 0], 0];
    Which[
     err == 2148916233, Print["[x] \:8fd9\:4e2a\:5fae\:8f6f\:8d26\:53f7\:6ca1\:6709\:4e70\:8fc7 Minecraft"],
     err == 2148916238, Print["[x] \:8d26\:53f7\:662f\:672a\:6210\:5e74\:ff0c\:5f97\:5148\:52a0\:8fdb\:5bb6\:5ead\:7ec4"],
     True, Print["[x] XSTS \:8ba4\:8bc1\:5931\:8d25"]];
    Return[$Failed]];

   uhs = Quiet@Check[xsts["DisplayClaims"]["xui"][[1]]["uhs"], ""];
   If[! StringQ[uhs] || uhs === "",
    Print["[x] XSTS \:54cd\:5e94\:91cc\:6ca1\:6709 uhs"]; Return[$Failed]];
   mc = postJson["https://api.minecraftservices.com/authentication/login_with_xbox",
     <|"identityToken" -> "XBL3.0 x=" <> uhs <> ";" <> xsts["Token"]|>, ""];
   If[! AssociationQ[mc] || ! KeyExistsQ[mc, "access_token"],
    Print["[x] \:6362 Minecraft \:51ed\:8bc1\:5931\:8d25"]; Return[$Failed]];

   prof = getJsonAuth["https://api.minecraftservices.com/minecraft/profile",
     mc["access_token"]];
   If[! AssociationQ[prof] || ! KeyExistsQ[prof, "id"],
    Print["[x] \:62ff\:4e0d\:5230\:6e38\:620f\:6863\:6848\:ff08\:8fd9\:8d26\:53f7\:53ef\:80fd\:6ca1\:4e70\:8fc7 Minecraft\:ff09"]; Return[$Failed]];

   <|"name" -> prof["name"], "uuid" -> prof["id"],
    "token" -> mc["access_token"], "refresh" -> refresh,
    "expires" -> AbsoluteTime[] + 72000|>];

msLogin[] := Module[{d, dc, interval, deadline, tok, res, a, n = 0, chain},
   Print[""];
   Print["==> \:6b63\:7248\:767b\:5f55\:ff1a\:5f85\:4f1a\:513f\:53bb\:6d4f\:89c8\:5668\:91cc\:8f93\:4e00\:4e2a\:7801"];
   d = postForm[$authBase <> "/devicecode",
     "client_id=" <> $clientId <> "&scope=XboxLive.signin%20offline_access"];
   If[! AssociationQ[d] || ! KeyExistsQ[d, "user_code"],
    Print["[x] \:62ff\:8bbe\:5907\:7801\:5931\:8d25\:ff1a",
     If[AssociationQ[d], Lookup[d, "error_description", "\:7f51\:7edc\:9519\:8bef"],
      "\:7f51\:7edc\:9519\:8bef\:ff0c\:8fde\:4e0d\:4e0a\:5fae\:8f6f"]];
    Return[$Failed]];

   Print["    \:5730\:5740: ", d["verification_uri"]];
   Print["    \:4ee3\:7801: ", d["user_code"]];
   Print["    ", Round[d["expires_in"]/60], " \:5206\:949f\:5185\:6709\:6548"];

   dc = d["device_code"];
   interval = Replace[Lookup[d, "interval", 5], _Missing -> 5];
   deadline = AbsoluteTime[] + d["expires_in"];
   tok = $Failed;
   While[AbsoluteTime[] < deadline,
    Pause[interval];
    res = postForm[$authBase <> "/token",
      "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=" <>
       $clientId <> "&device_code=" <> dc];
    n++;
    If[AssociationQ[res] && KeyExistsQ[res, "access_token"], tok = res; Break[]];
    If[AssociationQ[res],
     If[Lookup[res, "error", ""] === "authorization_declined",
      Print["[x] \:4f60\:5728\:6d4f\:89c8\:5668\:91cc\:70b9\:4e86\:62d2\:7edd"]; Return[$Failed]];
     If[Lookup[res, "error", ""] =!= "authorization_pending",
      Print["[x] \:767b\:5f55\:5931\:8d25: ", Lookup[res, "error_description", ""]];
      Return[$Failed]]];
    If[Mod[n, 6] === 0,
     Print["    \:2026 \:8fd8\:5728\:7b49\:ff08\:5269 ", Round[deadline - AbsoluteTime[]], " \:79d2\:ff09"]]];

   If[tok === $Failed, Print["[x] \:7b49\:592a\:4e45\:4e86\:ff0c\:8d85\:65f6\:ff0c\:91cd\:65b0\:767b\:5f55\:4e00\:6b21"]; Return[$Failed]];
   Print["    \:786e\:8ba4\:4e86\:ff0c\:6b63\:5728\:6362 Minecraft \:51ed\:8bc1\:2026"];

   chain = mcChain[tok["access_token"], tok["refresh_token"]];
   If[chain === $Failed, Return[$Failed]];

   upsertAccount[chain];
   Export[$tokenFile, chain, "JSON"];
   setPrivate[$tokenFile];
   Print["==> \:767b\:5f55\:6210\:529f\:ff1a", chain["name"]];
   chain];

msRefresh[t_] := Module[{res, chain},
   Print["==> \:5237\:65b0\:767b\:5f55\:51ed\:8bc1\:2026"];
   res = postForm[$authBase <> "/token",
     "grant_type=refresh_token&client_id=" <> $clientId <>
      "&refresh_token=" <> t["refresh"] <> "&scope=XboxLive.signin%20offline_access"];
   If[! AssociationQ[res] || ! KeyExistsQ[res, "access_token"],
    Print["[x] \:5237\:65b0\:5931\:8d25\:ff08refresh_token \:53ef\:80fd\:8fc7\:671f\:ff09\:ff0c\:6309 7 \:91cd\:65b0\:767b\:5f55"];
    Return[$Failed]];
   chain = mcChain[res["access_token"],
     Replace[Lookup[res, "refresh_token", ""], "" -> t["refresh"]]];
   If[chain === $Failed, Return[$Failed]];
   upsertAccount[chain];
   Export[$tokenFile, chain, "JSON"];
   setPrivate[$tokenFile];
   <|"name" -> chain["name"], "uuid" -> chain["uuid"],
    "token" -> chain["token"], "type" -> "msa"|>];

ensureAuth[cfg_Association] := Module[{a, exp},
   migrateTokenFile[];
   a = activeAccount[cfg];
   If[! AssociationQ[a],
    Print["[x] \:8fd8\:6ca1\:6709\:5fae\:8f6f\:8d26\:53f7\:ff0c\:6309 7 \:6dfb\:52a0\:4e00\:4e2a"]; Return[$Failed]];
   exp = Lookup[a, "expires", 0];
   If[NumberQ[exp] && exp > AbsoluteTime[] + 300 &&
     StringQ[Lookup[a, "token", ""]] && Lookup[a, "token", ""] =!= "",
    Return[<|"name" -> a["name"], "uuid" -> a["uuid"],
      "token" -> a["token"], "type" -> "msa"|>]];
   msRefresh[a]];

switchAccount[cfg_Association] := Module[{l, cur, t, i, j, chosen},
   l = loadAccounts[];
   If[l === {}, Print["  \:8fd8\:6ca1\:6709\:5fae\:8f6f\:8d26\:53f7"]; Return[cfg]];
   cur = If[AssociationQ[activeAccount[cfg]], activeAccount[cfg]["uuid"], ""];
   Do[Print["   ", j, ") ", escName[l[[j]]],
     If[l[[j]]["uuid"] === cur, "  <== \:5f53\:524d", ""]], {j, Length[l]}];
   t = askLine["  \:9009\:54ea\:4e2a > "];
   i = Quiet@Check[ToExpression[t], $Failed];
   If[! (IntegerQ[i] && 1 <= i <= Length[l]), Return[cfg]];
   chosen = l[[i]];
   $auth = <|"name" -> chosen["name"], "uuid" -> chosen["uuid"],
     "token" -> Lookup[chosen, "token", "0"], "type" -> "msa"|>;
   Print["==> \:5df2\:5207\:5230 ", chosen["name"]];
   Join[cfg, <|"account" -> "microsoft", "active" -> chosen["uuid"]|>]];

delAccount[cfg_Association] := Module[{l, cur, t, i, j, victim},
   l = loadAccounts[];
   If[l === {}, Print["  \:6ca1\:6709\:53ef\:5220\:7684\:8d26\:53f7"]; Return[cfg]];
   cur = If[AssociationQ[activeAccount[cfg]], activeAccount[cfg]["uuid"], ""];
   Do[Print["   ", j, ") ", l[[j]]["name"]], {j, Length[l]}];
   t = askLine["  \:5220\:54ea\:4e2a > "];
   i = Quiet@Check[ToExpression[t], $Failed];
   If[! (IntegerQ[i] && 1 <= i <= Length[l]), Return[cfg]];
   victim = l[[i]];
   removeAccount[victim["uuid"]];
   Print["==> \:5df2\:5220\:9664 ", victim["name"]];
   If[victim["uuid"] === cur,
    Join[cfg, <|"account" -> "offline", "active" -> ""|>], cfg]];

acctMenu[cfg0_Association] := Module[{c, cfg = cfg0},
   While[True,
    Print[""];
    Print["  --------------------------------------------"];
    Print["  \:8d26\:53f7\:7ba1\:7406"];
    Print["  \:5f53\:524d\:ff1a" <> accountLabel[cfg]];
    Print["  \:672c\:673a\:5df2\:4fdd\:5b58\:ff1a" <> ToString[Length[loadAccounts[]]] <> " \:4e2a\:8d26\:53f7"];
    Print["  --------------------------------------------"];
    Print["  1) \:79bb\:7ebf\:6a21\:5f0f"];
    Print["  2) \:6dfb\:52a0\:5fae\:8f6f\:8d26\:53f7\:ff08\:8bbe\:5907\:7801\:767b\:5f55\:ff09"];
    Print["  3) \:5207\:6362\:8d26\:53f7"];
    Print["  4) \:5220\:9664\:8d26\:53f7"];
    Print["  q) \:8fd4\:56de"];
    c = askLine["  \:9009\:62e9 > "];
    If[c === $Failed || c === "q" || c === "Q" || c === "", Return[cfg]];
    Switch[c,
     "1",
      $auth = <|"name" -> cfg["user"],
        "uuid" -> "00000000000000000000000000000000",
        "token" -> "0", "type" -> "legacy"|>;
      cfg = Join[cfg, <|"account" -> "offline", "active" -> ""|>],
     "2",
      Module[{a},
       a = msLogin[];
       If[AssociationQ[a],
        $auth = <|"name" -> a["name"], "uuid" -> a["uuid"],
          "token" -> a["token"], "type" -> "msa"|>;
        cfg = Join[cfg, <|"account" -> "microsoft", "active" -> a["uuid"]|>]]],
     "3", cfg = switchAccount[cfg],
     "4", cfg = delAccount[cfg],
     _, Print["  ? \:6ca1\:6709\:8fd9\:4e2a\:9009\:9879"]]]];

downloadAsk[cfg0_] := Module[{cfg = cfg0, m, rel, c, i, gv, r, lc, f,
    dir, name, url, size},
   m = getJson[$manifestUrl];
   If[! AssociationQ[m], Print["  [x] \:62c9\:4e0d\:5230\:7248\:672c\:6e05\:5355"]; Return[cfg]];
   rel = Select[m["versions"], Lookup[#, "type", ""] === "release" &][[All, "id"]];
   Print[""];
   Print["  \:53ef\:9009\:7248\:672c\:ff08\:6700\:65b0\:5728\:524d\:ff0c\:4e5f\:53ef\:4ee5\:76f4\:63a5\:6572\:7248\:672c\:53f7\:ff09"];
   Do[Print["   ", k, ") ", rel[[k]]], {k, Min[12, Length[rel]]}];
   c = askLine["  \:9009\:62e9 > "];
   If[c === $Failed || ! StringQ[c] || StringTrim[c] === "", Return[cfg]];
   c = StringTrim[c];
   i = Quiet@Check[ToExpression[c], $Failed];
   gv = If[IntegerQ[i] && 1 <= i <= Min[12, Length[rel]], rel[[i]], c];
   Print["  ==> \:76ee\:6807\:7248\:672c: ", gv];
   r = run[Join[cfg, <|"version" -> gv|>], "download"];
   If[! AssociationQ[r], Return[cfg]];
   Print["==> ", r["id"], " \:88c5\:597d\:4e86\:ff1a", r["libs"], " \:4e2a\:5e93\:3001", r["objs"], " \:4e2a\:8d44\:6e90"];
   cfg["version"] = gv;
   saveCfg[cfg];
   Print[""];
   Print["  \:8981\:4e0d\:8981\:987a\:4fbf\:88c5\:4e2a\:6a21\:7ec4\:52a0\:8f7d\:5668\:ff1f"];
   Print["   1) \:4e0d\:7528   2) Fabric   3) Forge   4) NeoForge"];
   lc = askLine["  \:9009\:62e9 > "];
   If[! StringQ[lc] || ! MemberQ[{"2", "3", "4"}, StringTrim[lc]], Return[cfg]];
   lc = StringTrim[lc];
   cfg = installLoader[cfg, gv, Switch[lc, "2", "1", "3", "2", "4", "3"]];
   If[lc === "2" && StringStartsQ[cfg["version"], "fabric-loader-"],
    Print["  \:5927\:591a\:6570 Fabric \:6a21\:7ec4\:8981 Fabric API\:ff0c\:8981\:4e0d\:8981\:4e00\:8d77\:4e0b\:ff1f(y/n) > "];
    If[StringMatchQ[StringTrim[askLine["  > "]], "y" | "Y"],
     f = mrVersions["fabric-api", gv, "fabric"];
     If[f === {},
      Print["  [x] \:6ca1\:627e\:5230\:9002\:914d\:7684 Fabric API"],
      f = First[Lookup[First[f], "files", {<||>}]];
      dir = FileNameJoin[{gameDirOf[cfg], "mods"}];
      ensureDir[dir];
      name = Lookup[f, "filename", "fabric-api.jar"];
      url = Lookup[f, "url", ""];
      size = Lookup[f, "size", 0];
      If[Quiet@Check[URLDownload[url, FileNameJoin[{dir, name}], TimeConstraint -> 300], $Failed] === $Failed,
       Print["  [x] \:4e0b\:8f7d\:5931\:8d25"],
       Print["  ==> \:5df2\:4e0b ", name, "  (", humanBytes[size], ")"]]]]];
   cfg];

loaderLabel[cfg_] := Which[
   Lookup[cfg, "loader", ""] === "fabric",
    "Fabric " <> If[Lookup[cfg, "loaderVer", ""] === "", "(\:6700\:65b0)", cfg["loaderVer"]],
   Lookup[cfg, "loader", ""] === "forge",
    "Forge " <> If[Lookup[cfg, "loaderVer", ""] === "", "(\:6700\:65b0)", cfg["loaderVer"]],
   Lookup[cfg, "loader", ""] === "neoforge",
    "NeoForge " <> If[Lookup[cfg, "loaderVer", ""] === "", "(\:6700\:65b0)", cfg["loaderVer"]],
   True, "\:539f\:7248"];

fabricLatest[] := Module[{j},
   j = getJson[$fabricMeta <> "/versions/loader"];
   If[! ListQ[j] || j === {}, Return[""]];
   Lookup[First[j], "version", ""]];

fabricJson[gv_, lv_] := getJson[$fabricMeta <> "/versions/loader/" <> gv <> "/" <> lv <> "/profile/json"];

forgeVersions[gv_] := Module[{f, txt, vs},
   f = FileNameJoin[{$TemporaryDirectory, "forge-meta-" <> gv <> ".xml"}];
   If[Quiet@Check[URLDownload[$forgeMaven <> "/maven-metadata.xml", f,
        TimeConstraint -> 120], $Failed] === $Failed, Return[{}]];
   txt = Quiet@Check[Import[f, "Text"], ""];
   If[! StringQ[txt], Return[{}]];
   vs = StringCases[txt, "<version>" ~~ v : (Except["<"] ..) ~~ "</version>" :> v];
   vs = DeleteDuplicates[
     StringTake[#, StringLength[gv] + 2 ;;] & /@
      Select[vs, StringStartsQ[#, gv <> "-"] &]];
   vs = Select[vs, ! StringContainsQ[#, "-"] &];
   SortBy[vs, ToExpression /@ StringSplit[#, "."] &]];

(* NeoForge \:7248\:672c\:53f7\:662f <MC \:4e3b\:6b21>.<patch>\:ff1aMC 26.3 \:2192 26.3.0.97\:ff0cMC 1.21.1 \:2192 21.1.172 *)
neoForgePrefix[gv_String] := If[StringStartsQ[gv, "1."], StringDrop[gv, 2], gv];

(* bmclapi \:7684 https \:4f1a\:8ba9 Wolfram \:5185\:7f6e curl \:62a5 SSL 35\:ff0c\:8fd9\:91cc\:9000\:56de\:7cfb\:7edf curl *)
dlCurl[url_String, file_String] := Module[{r},
   If[FileExistsQ[file], Quiet@DeleteFile[file]];
   r = Quiet@Check[RunProcess[{"curl", "-sL", "--max-time", "180", "-o", file, url}], $Failed];
   If[r === $Failed, Return[$Failed]];
   If[r["ExitCode"] === 0 && FileExistsQ[file] && FileByteCount[file] > 0, file, $Failed]];

neoForgeVersions[gv_] := Module[{f, txt, vs, pre},
   pre = neoForgePrefix[gv];
   f = FileNameJoin[{$TemporaryDirectory, "neoforge-meta.xml"}];
   If[dlCurl[$neoForgeMaven <> "/net/neoforged/neoforge/maven-metadata.xml", f] === $Failed,
    Return[{}]];
   txt = Quiet@Check[Import[f, "Text"], ""];
   If[! StringQ[txt], Return[{}]];
   vs = StringCases[txt, "<version>" ~~ v : (Except["<"] ..) ~~ "</version>" :> v];
   vs = Select[Select[vs, StringStartsQ[#, pre <> "."] &],
     ! StringContainsQ[#, "-"] &];
   SortBy[vs, ToExpression /@ StringSplit[#, "."] &]];

installNeoForge[gv_, fv_, java_] := Module[{d, url, inst, r, id2, json},
   id2 = "neoforge-" <> fv;
   json = FileNameJoin[{$mcVersions, id2, id2 <> ".json"}];
   If[FileExistsQ[json], Return[json]];
   d = FileNameJoin[{$mcHome, "forge"}];
   ensureDir[d];
   url = $neoForgeMaven <> "/net/neoforged/neoforge/" <> fv <>
     "/neoforge-" <> fv <> "-installer.jar";
   inst = FileNameJoin[{d, "neoforge-" <> fv <> "-installer.jar"}];
   If[! FileExistsQ[inst] || FileByteCount[inst] < 1000000,
    If[dlCurl[url, inst] === $Failed,
     Print["    [x] NeoForge \:5b89\:88c5\:5668\:4e0b\:8f7d\:5931\:8d25"]; Return[$Failed]]];
   Print["    \:8fd0\:884c NeoForge \:5b89\:88c5\:5668\:ff08\:7b2c\:4e00\:6b21\:8981\:4e0b\:51e0\:5341 MB\:ff09\:2026"];
   r = Quiet@Check[RunProcess[{java, "-jar", inst, "--installClient", $mcHome}], $Failed];
   If[r === $Failed, Print["    [x] \:5b89\:88c5\:5668\:65e0\:6cd5\:542f\:52a8"]; Return[$Failed]];
   If[r["ExitCode"] =!= 0,
    Print["    [x] \:5b89\:88c5\:5668\:9000\:51fa\:7801 ", r["ExitCode"]];
    Print["    ", StringTake[r["StandardOutput"], UpTo[400]]];
    Return[$Failed]];
   If[FileExistsQ[json], json, Return[$Failed]]];

(* ---------------- \:7248\:672c\:89e3\:6790\:ff08\:6309\:5b98\:65b9 inheritsFrom \:9012\:5f52\:5408\:5e76\:ff09 ---------------- *)
loadVersionJson[id_String] := Module[{f, j, pid, pj},
   f = FileNameJoin[{$mcVersions, id, id <> ".json"}];
   If[! FileExistsQ[f], Return[$Failed]];
   j = Quiet@Check[Import[f, "RawJSON"], $Failed];
   If[! AssociationQ[j], Return[$Failed]];
   pid = Lookup[j, "inheritsFrom", None];
   If[StringQ[pid],
    pj = loadVersionJson[pid];
    If[AssociationQ[pj], Return[mergeInherited[pj, j]]]];
   j];

mergeInherited[base_, child_] := Module[{m, aa, ab, c},
   m = base;
   Do[
    If[KeyExistsQ[child, k],
     c = child[k];
     (* 子版本里空的 logging / downloads 是占位，不能盖掉父版本的真值 *)
     If[! (AssociationQ[c] && Length[c] === 0) &&
        ! (ListQ[c] && Length[c] === 0),
      m[k] = c]],
    {k, {"id", "mainClass", "minecraftArguments", "type", "assets",
      "assetIndex", "javaVersion", "downloads", "logging",
      "complianceLevel", "releaseTime", "time"}}];
   m["libraries"] = Join[Lookup[base, "libraries", {}],
     Lookup[child, "libraries", {}]];
   aa = Lookup[base, "arguments", <||>];
   ab = Lookup[child, "arguments", <||>];
   If[AssociationQ[ab] || AssociationQ[aa],
    m["arguments"] = <|
      "game" -> Join[Lookup[aa, "game", {}], Lookup[ab, "game", {}]],
      "jvm" -> Join[Lookup[aa, "jvm", {}], Lookup[ab, "jvm", {}]]|>];
   m];

versionJarId[id_String] := Module[{p},
   If[FileExistsQ[FileNameJoin[{$mcVersions, id, id <> ".jar"}]], Return[id]];
   p = Quiet@Check[Import[FileNameJoin[{$mcVersions, id, id <> ".json"}], "RawJSON"], $Failed];
   If[AssociationQ[p] && StringQ[Lookup[p, "inheritsFrom", None]],
    Return[versionJarId[p["inheritsFrom"]]]];
   id];

pickVersion[cfg0_Association] := Module[{cfg = cfg0, vs, i, n},
   vs = localVersions[];
   If[vs === {}, Print["  \:8fd8\:6ca1\:6709\:88c5\:4efb\:4f55\:7248\:672c\:ff0c\:5148\:6309 9 \:4e0b\:8f7d"]; Return[cfg]];
   Print[""];
   Print["  \:9009\:62e9\:8981\:542f\:52a8\:7684\:7248\:672c\:ff1a"];
   Do[Print["   ", n, ") ", vs[[n]]], {n, Length[vs]}];
   i = askLine["  \:5e8f\:53f7\:ff08\:56de\:8f66\:53d6\:6d88\:ff09> "];
   If[! StringQ[i] || StringTrim[i] === "", Return[cfg]];
   i = Quiet@Check[ToExpression[StringTrim[i]], $Failed];
   If[! IntegerQ[i] || i < 1 || i > Length[vs],
    Print["  \:5e8f\:53f7\:4e0d\:5bf9"]; Return[cfg]];
   cfg["version"] = vs[[i]];
   saveCfg[cfg];
   Print["  ==> ", cfg["version"]];
   cfg];

installLoader[cfg0_Association, base0_String : "", lc0_String : ""] := Module[{cfg = cfg0, vs, c, base, lv, lv2,
    javaInfo, java, j, id2, f, n},
   base = base0;
   If[base === "",
    vs = Select[localVersions[],
      Function[v, ! StringContainsQ[v, "-forge-"] &&
         ! StringStartsQ[v, "fabric-loader-"] &&
         ! StringStartsQ[v, "neoforge-"]]];
    If[vs === {}, Print["  \:5148\:6309 9 \:4e0b\:8f7d\:4e00\:4e2a\:539f\:7248\:ff0c\:518d\:6765\:88c5\:52a0\:8f7d\:5668"]; Return[cfg]];
    Print[""];
    Print["  \:57fa\:4e8e\:54ea\:4e2a\:539f\:7248\:88c5\:52a0\:8f7d\:5668\:ff1a"];
    Do[Print["   ", n, ") ", vs[[n]]], {n, Length[vs]}];
    c = askLine["  \:5e8f\:53f7\:ff08\:56de\:8f66\:53d6\:6d88\:ff09> "];
    If[! StringQ[c] || StringTrim[c] === "", Return[cfg]];
    c = Quiet@Check[ToExpression[StringTrim[c]], $Failed];
    If[! IntegerQ[c] || c < 1 || c > Length[vs],
     Print["  \:5e8f\:53f7\:4e0d\:5bf9"]; Return[cfg]];
    base = vs[[c]]];
   c = lc0;
   If[c === "",
    Print[""];
    Print["  \:88c5\:54ea\:4e2a\:52a0\:8f7d\:5668\:ff1a"];
    Print["   1) Fabric   2) Forge   3) NeoForge"];
    c = askLine["  \:9009\:62e9\:ff08\:56de\:8f66\:53d6\:6d88\:ff09> "];
    If[! StringQ[c] || StringTrim[c] === "", Return[cfg]]];
   If[! MemberQ[{"1", "2", "3"}, StringTrim[c]], Return[cfg]];
   c = StringTrim[c];
   javaInfo = pickJava[21];
   java = If[javaInfo === $Failed, "java", First[javaInfo]];
   Switch[c,
    "1",
     lv = fabricLatest[];
     If[lv === "", Print["  [x] \:62ff\:4e0d\:5230 Fabric \:7248\:672c\:5217\:8868"]; Return[cfg]];
     lv2 = askLine["  Fabric Loader \:7248\:672c\:ff08\:56de\:8f66\:7528\:6700\:65b0 " <> lv <> "\:ff09> "];
     If[StringQ[lv2] && StringTrim[lv2] =!= "", lv = StringTrim[lv2]];
     j = fabricJson[base, lv];
     If[! AssociationQ[j], Print["  [x] \:62ff\:4e0d\:5230 Fabric \:5b89\:88c5\:914d\:7f6e"]; Return[cfg]];
     id2 = "fabric-loader-" <> lv <> "-" <> base;
     j["id"] = id2;
     f = FileNameJoin[{$mcVersions, id2, id2 <> ".json"}];
     ensureDir[DirectoryName[f]];
     Export[f, j, "JSON"],
    "2",
     lv = Last[forgeVersions[base]];
     If[lv === "", Print["  [x] ", base, " \:6ca1\:6709\:53ef\:7528\:7684 Forge"]; Return[cfg]];
     lv2 = askLine["  Forge \:7248\:672c\:ff08\:56de\:8f66\:7528\:6700\:65b0 " <> lv <> "\:ff09> "];
     If[StringQ[lv2] && StringTrim[lv2] =!= "", lv = StringTrim[lv2]];
     If[installForge[base, lv, java] === $Failed, Return[cfg]];
     id2 = base <> "-forge-" <> lv,
    "3",
     lv = Last[neoForgeVersions[base]];
     If[lv === "", Print["  [x] ", base, " \:6ca1\:6709\:53ef\:7528\:7684 NeoForge"]; Return[cfg]];
     lv2 = askLine["  NeoForge \:7248\:672c\:ff08\:56de\:8f66\:7528\:6700\:65b0 " <> lv <> "\:ff09> "];
     If[StringQ[lv2] && StringTrim[lv2] =!= "", lv = StringTrim[lv2]];
     If[installNeoForge[base, lv, java] === $Failed, Return[cfg]];
     id2 = "neoforge-" <> lv,
    _, Return[cfg]];
   If[FileExistsQ[FileNameJoin[{$mcVersions, id2, id2 <> ".json"}]],
    cfg["version"] = id2;
    saveCfg[cfg];
    Print["  ==> \:5df2\:88c5\:597d ", id2, "\:ff0c\:5df2\:5207\:5230\:8fd9\:4e2a\:7248\:672c"],
    Print["  [x] \:5b89\:88c5\:6ca1\:6709\:751f\:6210\:7248\:672c\:6587\:4ef6"]];
   cfg];

installForge[gv_, fv_, java_] := Module[{d, url, inst, r, id2, json, lp},
   id2 = gv <> "-forge-" <> fv;
   json = FileNameJoin[{$mcVersions, id2, id2 <> ".json"}];
   If[FileExistsQ[json], Return[json]];
   d = FileNameJoin[{$mcHome, "forge"}];
   ensureDir[d];
   (* Forge \:5b89\:88c5\:5668\:8981\:6c42\:5b58\:5728\:5b98\:65b9\:542f\:52a8\:5668\:7684 profile \:6587\:4ef6\:ff0c\:5426\:5219\:76f4\:63a5\:62a5\:9519\:9000\:51fa *)
   lp = FileNameJoin[{$mcHome, "launcher_profiles.json"}];
   If[! FileExistsQ[lp],
    Export[lp, "{\"profiles\":{},\"settings\":{},\"version\":3}", "Text"]];
   url = $forgeMaven <> "/" <> gv <> "-" <> fv <> "/forge-" <> gv <> "-" <> fv <> "-installer.jar";
   inst = FileNameJoin[{d, "forge-" <> gv <> "-" <> fv <> "-installer.jar"}];
   If[! FileExistsQ[inst] || FileByteCount[inst] < 1000000,
    If[dl[url, inst] === $Failed,
     Print["    [x] Forge \:5b89\:88c5\:5668\:4e0b\:8f7d\:5931\:8d25"]; Return[$Failed]]];
   Print["    \:8fd0\:884c Forge \:5b89\:88c5\:5668\:ff08\:7b2c\:4e00\:6b21\:8981\:4e0b\:51e0\:5341 MB\:ff09\:2026"];
   r = Quiet@Check[RunProcess[{java, "-jar", inst, "--installClient", $mcHome}], $Failed];
   If[r === $Failed, Print["    [x] \:5b89\:88c5\:5668\:65e0\:6cd5\:542f\:52a8"]; Return[$Failed]];
   If[r["ExitCode"] =!= 0,
    Print["    [x] \:5b89\:88c5\:5668\:9000\:51fa\:7801 ", r["ExitCode"]];
    Print["    ", StringTake[r["StandardOutput"], UpTo[400]]];
    Return[$Failed]];
   If[FileExistsQ[json], json, Return[$Failed]]];

baseOf[id_String] := Module[{f, j},
   f = FileNameJoin[{$mcVersions, id, id <> ".json"}];
   If[! FileExistsQ[f], Return[id]];
   j = Quiet@Check[Import[f, "RawJSON"], <||>];
   If[! AssociationQ[j], Return[id]];
   Lookup[j, "inheritsFrom", id]];

$modrinthApi = "https://api.modrinth.com/v2";

mrSearch[q_String, type_String, n_Integer : 8] := Module[{u, j},
   u = $modrinthApi <> "/search?limit=" <> ToString[n] <>
     "&query=" <> URLEncode[q] <>
     "&facets=" <> URLEncode["[[\"project_type:" <> type <> "\"]]"];
   j = getJson[u];
   If[! AssociationQ[j], Return[{}]];
   Lookup[j, "hits", {}]];

mrVersions[slug_String, gv_String, ld_String : ""] := Module[{u, j},
   u = $modrinthApi <> "/project/" <> slug <> "/version?game_versions=" <>
     URLEncode["[\"" <> gv <> "\"]"];
   If[ld =!= "", u = u <> "&loaders=" <> URLEncode["[\"" <> ld <> "\"]"]];
   j = getJson[u];
   If[! ListQ[j], Return[{}]];
   j];

mcVersionId[cfg_] := Module[{m, v},
   v = cfg["version"];
   If[v === Automatic,
    m = getJson[$manifestUrl];
    Return[If[AssociationQ[m], m["latest", "release"], "latest"]]];
   baseOf[v]];

resDownload[cfg0_Association] := Module[{cfg = cfg0, q, hits, i, hit, slug,
    gv, vers, f, dest, url, name, size, dir, k},
   gv = mcVersionId[cfg];
   Print[""];
   Print["  \:8d44\:6e90\:4e0b\:8f7d  \:ff08\:8d44\:6e90\:5305\:ff0c\:9002\:914d Minecraft ", gv, "\:ff09"];
   Print["  --------------------------------------------"];
   q = askLine["  \:641c\:7d22\:5173\:952e\:8bcd\:ff08\:56de\:8f66\:8fd4\:56de\:ff09> "];
   If[! StringQ[q] || StringTrim[q] === "", Return[cfg]];
   q = StringTrim[q];
   Print["  \:6b63\:5728\:641c\:7d22\:2026"];
   hits = mrSearch[q, "resourcepack", 8];
   If[hits === {}, Print["  [x] \:6ca1\:641c\:5230\:ff0c\:6216\:7f51\:7edc\:4e0d\:901a"]; Return[cfg]];
   Print["  ==> \:627e\:5230 ", Length[hits], " \:4e2a\:ff1a"];
   Do[
    hit = hits[[k]];
    Print["   ", k, ") ", Lookup[hit, "title", "?"], "    ",
     Lookup[hit, "downloads", 0], " \:6b21\:4e0b\:8f7d"],
    {k, Length[hits]}];
   i = askLine["  \:9009\:4e00\:4e2a\:ff08\:5e8f\:53f7\:ff0c\:56de\:8f66\:53d6\:6d88\:ff09> "];
   If[! StringQ[i] || StringTrim[i] === "", Return[cfg]];
   i = Quiet@Check[ToExpression[StringTrim[i]], $Failed];
   If[! IntegerQ[i] || i < 1 || i > Length[hits],
    Print["  \:5e8f\:53f7\:4e0d\:5bf9"]; Return[cfg]];
   hit = hits[[i]];
   slug = Lookup[hit, "slug", ""];
   Print["  ==> \:67e5 ", Lookup[hit, "title", slug], " \:9002\:914d ", gv, " \:7684\:6587\:4ef6\:2026"];
   vers = mrVersions[slug, gv];
   If[vers === {}, Print["  [x] \:8fd9\:4e2a\:8d44\:6e90\:5305\:6ca1\:6709\:9002\:914d ", gv, " \:7684\:7248\:672c"]; Return[cfg]];
   f = Lookup[First[vers], "files", {}];
   If[f === {}, Print["  [x] \:7248\:672c\:91cc\:6ca1\:6709\:53ef\:7528\:6587\:4ef6"]; Return[cfg]];
   f = First[f];
   url = Lookup[f, "url", ""];
   name = Lookup[f, "filename", slug <> ".zip"];
   size = Lookup[f, "size", 0];
   dir = FileNameJoin[{gameDirOf[cfg], "resourcepacks"}];
   ensureDir[dir];
   dest = FileNameJoin[{dir, name}];
   Print["  ==> \:4e0b\:8f7d ", name, "  (", humanBytes[size], ")"];
   Print["      \:5230 ", dir];
   If[Quiet@Check[URLDownload[url, dest, TimeConstraint -> 300], $Failed] === $Failed,
    Print["  [x] \:4e0b\:8f7d\:5931\:8d25"],
    If[FileExistsQ[dest] && (size === 0 || FileByteCount[dest] === size),
     Print["  ==> \:88c5\:597d\:4e86\:ff0c\:8fdb\:6e38\:620f\:5728\:300c\:9009\:9879 \:2192 \:8d44\:6e90\:5305\:300d\:91cc\:542f\:7528"],
     Print["  [!] \:6587\:4ef6\:5927\:5c0f\:5bf9\:4e0d\:4e0a\:ff0c\:53ef\:80fd\:6ca1\:4e0b\:5b8c"]]];
   cfg];

(* ---------------- \:6a21\:7ec4 ---------------- *)
loaderOf[id_String] := Which[
   StringContainsQ[id, "neoforge"], "neoforge",
   StringContainsQ[id, "forge"], "forge",
   StringContainsQ[id, "fabric"], "fabric",
   True, "vanilla"];

loaderName[l_String] := Switch[l,
   "fabric", "Fabric",
   "forge", "Forge",
   "neoforge", "NeoForge",
   _, "\:539f\:7248"];

modKind[jar_String] := Module[{r},
   r = Quiet@Check[RunProcess[{"unzip", "-l", jar}]["StandardOutput"], ""];
   Which[
    StringContainsQ[r, "fabric.mod.json"], "fabric",
    StringContainsQ[r, "META-INF/neoforge.mods.toml"], "neoforge",
    StringContainsQ[r, "META-INF/mods.toml"], "forge",
    True, "unknown"]];

modsDirOf[cfg_Association] := FileNameJoin[{gameDirOf[cfg], "mods"}];

listMods[cfg_Association] := Module[{d, fs},
   d = modsDirOf[cfg];
   If[! DirectoryQ[d], Return[{}]];
   fs = Quiet@Check[FileNames["*.jar", d], {}];
   Function[f, <|"file" -> f, "name" -> FileNameTake[f],
      "size" -> Quiet@Check[FileByteCount[f], 0],
      "kind" -> modKind[f]|>] /@ fs];

printMods[cfg_Association] := Module[{ms, ld},
   ld = loaderOf[cfg["version"]];
   ms = listMods[cfg];
   Print[""];
   Print["  \:6a21\:7ec4  \:ff08", cfg["version"], " / ", loaderName[ld], "\:ff09  \:5171 ", Length[ms], " \:4e2a"];
   Print["  --------------------------------------------"];
   If[ms === {},
    Print["  mods/ \:8fd8\:662f\:7a7a\:7684"],
    Do[
     Print["   ", k, ") ", ms[[k]]["name"], "  ", humanBytes[ms[[k]]["size"]],
      "   [", ms[[k]]["kind"], "]",
      If[ms[[k]]["kind"] === "fabric" && MemberQ[{"forge", "neoforge"}, ld],
       "   [!] \:5f53\:524d\:52a0\:8f7d\:5668\:7528\:4e0d\:4e86", ""]],
     {k, Length[ms]}]]];

modDownload[cfg_Association] := Module[{ld, gv, q, hits, i, hit, vers, f, dir,
    dest, name, size, k},
   gv = baseOf[cfg["version"]];
   ld = loaderOf[cfg["version"]];
   If[ld === "vanilla",
    Print["  [!] \:539f\:7248\:6ca1\:6709\:6a21\:7ec4\:52a0\:8f7d\:5668\:ff0c\:5148\:6309 m \:4e0a\:9762\:7684 a \:88c5\:4e00\:4e2a\:518d\:4e0b\:6a21\:7ec4"]; Return[cfg]];
   Print[""];
   q = askLine["  \:641c\:7d22\:6a21\:7ec4\:ff08\:56de\:8f66\:8fd4\:56de\:ff09> "];
   If[! StringQ[q] || StringTrim[q] === "", Return[cfg]];
   q = StringTrim[q];
   Print["  \:6b63\:5728\:641c\:7d22\:2026"];
   hits = mrSearch[q, "mod", 8];
   If[hits === {}, Print["  [x] \:6ca1\:641c\:5230\:ff0c\:6216\:7f51\:7edc\:4e0d\:901a"]; Return[cfg]];
   Print["  ==> \:627e\:5230 ", Length[hits], " \:4e2a\:ff1a"];
   Do[
    hit = hits[[k]];
    Print["   ", k, ") ", Lookup[hit, "title", "?"], "    ",
     Lookup[hit, "downloads", 0], " \:6b21\:4e0b\:8f7d"],
    {k, Length[hits]}];
   i = askLine["  \:9009\:4e00\:4e2a\:ff08\:5e8f\:53f7\:ff0c\:56de\:8f66\:53d6\:6d88\:ff09> "];
   If[! StringQ[i] || StringTrim[i] === "", Return[cfg]];
   i = Quiet@Check[ToExpression[StringTrim[i]], $Failed];
   If[! IntegerQ[i] || i < 1 || i > Length[hits],
    Print["  \:5e8f\:53f7\:4e0d\:5bf9"]; Return[cfg]];
   hit = hits[[i]];
   Print["  ==> \:67e5\:9002\:914d ", gv, " / ", loaderName[ld], " \:7684\:6587\:4ef6\:2026"];
   vers = mrVersions[Lookup[hit, "slug", ""], gv, ld];
   If[vers === {},
    Print["  [x] \:8fd9\:4e2a\:6a21\:7ec4\:6ca1\:6709\:9002\:914d ", gv, " \:7684 ", loaderName[ld], " \:7248\:672c"]; Return[cfg]];
   f = Lookup[First[vers], "files", {}];
   If[f === {}, Print["  [x] \:7248\:672c\:91cc\:6ca1\:6709\:53ef\:7528\:6587\:4ef6"]; Return[cfg]];
   f = First[f];
   dir = modsDirOf[cfg];
   ensureDir[dir];
   name = Lookup[f, "filename", "mod.jar"];
   size = Lookup[f, "size", 0];
   dest = FileNameJoin[{dir, name}];
   Print["  ==> \:4e0b\:8f7d ", name, "  (", humanBytes[size], ")"];
   If[Quiet@Check[URLDownload[Lookup[f, "url", ""], dest, TimeConstraint -> 300], $Failed] === $Failed,
    Print["  [x] \:4e0b\:8f7d\:5931\:8d25"],
    Print["  ==> \:653e\:597d\:4e86\:ff0c\:4e0b\:6b21\:542f\:52a8\:5c31\:751f\:6548"]];
   cfg];

modMenu[cfg0_Association] := Module[{cfg = cfg0, c, ms, i},
   While[True,
    printMods[cfg];
    Print["  --------------------------------------------"];
    Print["  1) \:4ece Modrinth \:4e0b\:8f7d   2) \:5220\:9664\:6a21\:7ec4   3) \:6253\:5f00 mods \:76ee\:5f55   0) \:8fd4\:56de"];
    c = askLine["  \:9009\:62e9 > "];
    If[c === $Failed, Return[cfg]];
    Switch[c,
     "1", cfg = modDownload[cfg],
     "2",
      ms = listMods[cfg];
      If[ms === {},
       Print["  mods/ \:662f\:7a7a\:7684"],
       i = askLine["  \:5220\:9664\:54ea\:4e2a\:ff08\:5e8f\:53f7\:ff09> "];
       i = Quiet@Check[ToExpression[StringTrim[i]], $Failed];
       If[IntegerQ[i] && 1 <= i <= Length[ms],
        Quiet@Check[DeleteFile[ms[[i]]["file"]], Null];
        Print["  ==> \:5df2\:5220\:9664 ", ms[[i]]["name"]],
        Print["  \:5e8f\:53f7\:4e0d\:5bf9"]]],
     "3", Quiet@Check[RunProcess[{"xdg-open", modsDirOf[cfg]}], Null],
     "0" | "", Return[cfg],
     _, Print["  ? \:6ca1\:6709\:8fd9\:4e2a\:9009\:9879"]]];
   cfg];

(* ---------------- 主流程 ---------------- *)
run[cfg_Association, mode_String : "launch"] := Module[{
   manifest, target, verJson, localJson, id, java, javaInfo, needJava, cp,
   nativesDir, clientJar,
   authName, authUuid, authToken, authType,
   libEntries, libPaths, sown, art, rel, dest, jvmArgs, gameArgs, natJars,
   legacy, na, jvmArgsRaw, gameArgsRaw,
   cmd, proc, line, n = 0, vars, logCfg, logPath, logArg, ai, aif,
   aIdx, objs2, assetRoot, missing, n2, missMB, dlOne, failCount,
   deadline, sz, printed = 0, extra, waitSec, jarId, eline},
   manifest = getJson[$manifestUrl];

   id = If[cfg["version"] === Automatic,
     If[manifest === $Failed,
      Print["[x] \:62ff\:4e0d\:5230\:7248\:672c\:6e05\:5355\:ff0c\:68c0\:67e5\:7f51\:7edc\:ff08\:4e5f\:53ef\:4ee5\:5148\:6309 7 \:9009\:672c\:5730\:7248\:672c\:ff09"];
      Return[$Failed],
      manifest["latest", "release"]],
     cfg["version"]];

   localJson = FileNameJoin[{$mcVersions, id, id <> ".json"}];
   verJson = If[FileExistsQ[localJson],
     Print["==> ", id, "  (\:672c\:5730)"];
     loadVersionJson[id],
     If[manifest === $Failed,
      Print["[x] \:7f51\:7edc\:4e0d\:53ef\:7528\:ff0c\:672c\:5730\:4e5f\:6ca1\:6709 ", id]; Return[$Failed],
      target = SelectFirst[manifest["versions"], #["id"] === id &];
      If[MissingQ[target], Print["[x] \:7248\:672c\:4e0d\:5b58\:5728: ", id]; Return[$Failed]];
      Print["==> Minecraft ", id, "  (", target["type"], ")"];
      getJson[target["url"]]]];
   If[verJson === $Failed, Print["[x] \:7248\:672c\:6e05\:5355\:62c9\:53d6\:5931\:8d25"]; Return[$Failed]];

   (* 清单落一份到 versions/<id>/，下次能认出来、也能离线用 *)
   If[! FileExistsQ[localJson],
    ensureDir[FileNameJoin[{$mcVersions, id}]];
    Quiet@Export[localJson, verJson, "JSON"]];

   needJava = Replace[Lookup[Lookup[verJson, "javaVersion", <||>],
      "majorVersion", 8], _Missing -> 8];
   javaInfo = pickJava[needJava];
   If[javaInfo === $Failed,
    Print["[x] \:627e\:4e0d\:5230\:53ef\:7528\:7684 Java\:ff08\:9700\:8981 Java ",
     needJava, "+ \:ff09"]; Return[$Failed]];
   java = First[javaInfo];
   Print["    Java   : ", java, "  (", Last[javaInfo], ")"];
   If[Last[javaInfo] < needJava,
    Print["    [!] \:8fd9\:4e2a\:7248\:672c\:9700\:8981 Java ", needJava,
     "+\:ff0c\:5f53\:524d\:53ea\:6709 Java ", Last[javaInfo],
     "\:ff0c\:53ef\:80fd\:65e0\:6cd5\:542f\:52a8"]];
   Print["    \:4e3b\:7c7b   : ", verJson["mainClass"]];

   jarId = versionJarId[id];
   (* --- client.jar --- *)
   clientJar = FileNameJoin[{$mcVersions, jarId, jarId <> ".jar"}];
   ensureDir[DirectoryName[clientJar]];
   art = verJson["downloads", "client"];
   Print["    client : ", IntegerPart[art["size"]/1024/1024], " MB"];
   If[dl[art["url"], clientJar, art["size"]] === $Failed,
    Print["[x] client.jar \:4e0b\:8f7d\:5931\:8d25"]; Return[$Failed]];

   (* --- libraries --- *)
   libEntries = Select[verJson["libraries"], libAllowed];
   Print["    \:5e93     : ", Length[libEntries], " \:4e2a\:ff08", $osLabel, " \:53ef\:7528\:ff09"];
   natJars = {};
   sown = Reap[
      Do[
       (* 普通 artifact（含 1.19+ 的 natives 变体，它们本身就在 artifact 里） *)
       art = Lookup[Lookup[lib, "downloads", <||>], "artifact", None];
       If[! AssociationQ[art] && StringQ[Lookup[lib, "url", None]],
        Module[{rl, dp, uu},
         rl = libRelPath[lib["name"]];
         If[rl =!= $Failed,
          dp = FileNameJoin[{$mcLibs, rl}];
          uu = StringReplace[Lookup[lib, "url", ""] <> StringReplace[rl, "\\" -> "/"], "\\" -> "/"];
          If[dl[uu, dp] =!= $Failed, Sow[dp]; n++]]]];
       If[AssociationQ[art],
        (* 关键：用清单给的 path。同一 Maven 坐标可能有主 jar+多个 natives 变体，
           自己按 name 推算会把它们算成同一个文件互相覆盖 *)
        rel = Lookup[art, "path", None];
        If[rel === None, rel = libRelPath[lib["name"]]];
        If[rel =!= $Failed && rel =!= None,
         dest = FileNameJoin[{$mcLibs, rel}];
         If[dl[art["url"], dest, art["size"]] =!= $Failed,
          Sow[dest]; n++;
          If[StringContainsQ[lib["name"], ":natives-"] ||
            StringContainsQ[lib["name"], ":natives_"],
           AppendTo[natJars, dest]];
          If[Mod[n, 10] === 0,
           showProg["\:5e93\:6587\:4ef6", n, Length[libEntries]]]]]];
       (* 旧版 natives 只解压、不进 classpath *)
       legacy = legacyNatives[lib];
       Do[
        rel = Lookup[na, "path", None];
        If[rel === None, rel = libRelPath[lib["name"]]];
        If[rel =!= $Failed && rel =!= None,
         dest = FileNameJoin[{$mcLibs, rel}];
         If[dl[na["url"], dest, na["size"]] =!= $Failed,
          AppendTo[natJars, dest]; n++;
          If[Mod[n, 10] === 0,
           showProg["\:5e93\:6587\:4ef6", n, Length[libEntries]]]]],
        {na, legacy}],
       {lib, libEntries}]][[2]];
   endProg[];
   libPaths = DeleteDuplicates@If[sown === {}, {}, First[sown]];
   Print["    \:5c31\:7eea   : ", Length[libPaths], " \:4e2a\:5e93"];

   (* --- natives 解压（旧版和 LWJGL natives 都需要） --- *)
   nativesDir = FileNameJoin[{$mcHome, "natives", id}];
   If[DirectoryQ[nativesDir],
    Quiet@Check[DeleteDirectory[nativesDir, DeleteContents -> True], Null]];
   ensureDir[nativesDir];
   Scan[extractInto[#, nativesDir] &, natJars];
   (* 去掉签名，免得旧版 lwjgl 因为 META-INF 冲突报错 *)
   Quiet@Check[DeleteDirectory[FileNameJoin[{nativesDir, "META-INF"}],
      DeleteContents -> True], Null];
   Print["    natives: ", Length[natJars], " \:4e2a\:5305\:5df2\:89e3\:538b\:5230 ", nativesDir];

   (* --- 日志配置 --- *)
   logArg = Nothing;
   If[KeyExistsQ[verJson, "logging"],
    logCfg = verJson["logging", "client", "file"];
    logPath = FileNameJoin[{$mcAssets, "log_configs", logCfg["id"]}];
    If[dl[logCfg["url"], logPath, logCfg["size"]] =!= $Failed,
     logArg = StringReplace[verJson["logging", "client", "argument"],
       "$" <> "{path}" -> logPath]]];

   (* --- 资源索引与本体 --- *)
   ai = verJson["assetIndex"];
   aif = FileNameJoin[{$mcAssets, "indexes", ai["id"] <> ".json"}];
   If[dl[ai["url"], aif, ai["size"]] === $Failed,
    Print["[x] asset index \:4e0b\:8f7d\:5931\:8d25"]; Return[$Failed]];
   aIdx = Quiet@Import[aif, "RawJSON"];
   (* objects 的 key 是虚拟路径，真正的 hash 在 value 里 *)
   objs2 = Values[aIdx["objects"]];
   assetRoot = FileNameJoin[{$mcAssets, "objects"}];
   missing = Select[objs2, Function[ob,
      With[{p = FileNameJoin[{assetRoot, StringTake[ob["hash"], 2], ob["hash"]}]},
       ! FileExistsQ[p] || FileByteCount[p] =!= ob["size"]]]];
   If[Length[missing] > 0,
    missMB = Round[Total[missing[[All, "size"]]]/1048576.];
    Print["    \:8d44\:6e90   : index ", ai["id"], "\:ff08", Length[objs2], " \:9879\:ff0c\:7f3a ",
     Length[missing], " \:9879 / ", missMB, " MB\:ff09"];
    Print["    \:4e0b\:8f7d\:8d44\:6e90\:672c\:4f53\:2026"];
    dlOne = Function[ob,
      Module[{p, u},
       p = FileNameJoin[{assetRoot, StringTake[ob["hash"], 2], ob["hash"]}];
       ensureDir[DirectoryName[p]];
       If[! (FileExistsQ[p] && FileByteCount[p] === ob["size"]),
        u = "https://resources.download.minecraft.net/" <>
          StringTake[ob["hash"], 2] <> "/" <> ob["hash"];
        Quiet@Check[URLDownload[u, p, TimeConstraint -> 120], Null]];
       If[FileExistsQ[p] && FileByteCount[p] === ob["size"], 1, 0]]];
    (* 有些 Wolfram Engine 没有并行子核，ParallelMap 会静默什么都不做 *)
    If[$KernelCount > 0,
     ParallelMap[dlOne, missing, Method -> "CoarsestGrained"],
     n2 = 0;
     Map[Function[ob,
        With[{ok = dlOne[ob]}, n2++;
         If[Mod[n2, 10] === 0,
          showProg["\:8d44\:6e90\:6587\:4ef6", n2, Length[missing]]]; ok]],
       missing];
     endProg[]];
    failCount = Length[Select[missing, Function[ob,
       With[{p = FileNameJoin[{assetRoot, StringTake[ob["hash"], 2], ob["hash"]}]},
        ! FileExistsQ[p] || FileByteCount[p] =!= ob["size"]]]]];
    If[failCount > 0,
     Print["    [!] ", failCount,
      " \:4e2a\:8d44\:6e90\:6ca1\:4e0b\:5b8c\:ff0c\:91cd\:8bd5\:6216\:68c0\:67e5\:7f51\:7edc"]],
    Print["    \:8d44\:6e90   : index ", ai["id"], "\:ff08", Length[objs2], " \:9879\:ff0c\:5df2\:9f50\:5168\:ff09"]];

   If[mode === "download",
    Print["==> \:5168\:90e8\:4e0b\:597d\:4e86\:ff1a", Length[libPaths], " \:4e2a\:5e93\:3001",
     Length[objs2], " \:4e2a\:8d44\:6e90"];
    Return[<|"id" -> id, "libs" -> Length[libPaths],
      "objs" -> Length[objs2]|>]];

   authName = $auth["name"]; authUuid = $auth["uuid"];
   authToken = $auth["token"]; authType = $auth["type"];

   (* --- 组装命令行 --- *)
   sz = StringSplit[cfg["size"], "x" | "X" | "\:00d7"];
   If[Length[sz] =!= 2, sz = {"1280", "720"}];
   cp = StringRiffle[Prepend[libPaths, clientJar], $pathSep];
   vars = <|
     "$" <> "{natives_directory}" -> nativesDir,
     "$" <> "{classpath}" -> cp,
     "$" <> "{launcher_name}" -> "WolframMC",
     "$" <> "{launcher_version}" -> "1.0",
     "$" <> "{version_name}" -> id,
     "$" <> "{game_directory}" -> gameDirOf[cfg],
     "$" <> "{library_directory}" -> $mcLibs,
     "$" <> "{classpath_separator}" -> $pathSep,
     "$" <> "{assets_root}" -> $mcAssets,
     "$" <> "{assets_index_name}" -> ai["id"],
     "$" <> "{auth_player_name}" -> authName,
     "$" <> "{auth_uuid}" -> authUuid,
     "$" <> "{auth_access_token}" -> authToken,
     "$" <> "{user_type}" -> authType,
     "$" <> "{version_type}" -> "release",
     "$" <> "{clientid}" -> "",
     "$" <> "{auth_xuid}" -> "",
     "$" <> "{user_properties}" -> "{}",
     "$" <> "{game_assets}" -> $mcAssets,
     "$" <> "{resolution_width}" -> First[sz],
     "$" <> "{resolution_height}" -> Last[sz],
     "$" <> "{quickPlayPath}" -> "",
     "$" <> "{quickPlaySingleplayer}" -> "",
     "$" <> "{quickPlayMultiplayer}" -> "",
     "$" <> "{quickPlayRealms}" -> ""|>;

   (* 1.13+ 用 arguments，更早的版本用 minecraftArguments 字符串 *)
   If[KeyExistsQ[verJson, "arguments"] &&
      KeyExistsQ[verJson["arguments"], "jvm"],
    jvmArgsRaw = expandArgs[verJson["arguments", "jvm"]],
    jvmArgsRaw = {"-Djava.library.path=" <> nativesDir, "-cp", cp}];
   If[KeyExistsQ[verJson, "arguments"] &&
      KeyExistsQ[verJson["arguments"], "game"],
    gameArgsRaw = expandArgs[verJson["arguments", "game"]],
    gameArgsRaw = If[StringQ[Lookup[verJson, "minecraftArguments", None]],
      StringSplit[verJson["minecraftArguments"]], {}]];

   jvmArgs = DeleteCases[Flatten[{fillVars[#, vars] & /@ jvmArgsRaw,
        logArg}], _Nothing | _Missing];
   (* macOS 上 LWJGL 要求主线程启动；新清单自带，旧版得补 *)
   If[$osName === "osx" && ! MemberQ[jvmArgs, "-XstartOnFirstThread"],
    jvmArgs = Prepend[jvmArgs, "-XstartOnFirstThread"]];
   (* 清单里的 -Dxxx=${natives_directory}/yyy 需要目录真的存在 *)
   Scan[Function[a,
      With[{p = StringReplace[a, RegularExpression["^-D[^=]+="] -> ""]},
       If[StringQ[p] && StringStartsQ[p, nativesDir] &&
          StringLength[p] > StringLength[nativesDir],
        ensureDir[p]]]], jvmArgs];
   gameArgs = cleanArgs[fillVars[#, vars] & /@ gameArgsRaw];

   cmd = Join[{java, "-Xmx" <> cfg["ram"], "-Xms1G"}, jvmArgs,
     extraArgs[cfg["jvm"]], {verJson["mainClass"]}, gameArgs,
     extraArgs[cfg["game"]]];

   Print["==> Java: ", java];
   Print["==> JVM \:53c2\:6570 ", Length[jvmArgs], " \:6761\:ff0c\:6e38\:620f\:53c2\:6570 ", Length[gameArgs], " \:6761"];

   (* \:52a0\:8f7d\:5668\:4e0e mod \:517c\:5bb9\:6027\:63d0\:793a *)
   With[{ld = loaderOf[id]},
    Scan[Function[m,
       If[m["kind"] === "fabric" && MemberQ[{"forge", "neoforge"}, ld],
        Print["  [!] ", m["name"], " \:662f Fabric \:6a21\:7ec4\:ff0c", loaderName[ld], " \:52a0\:8f7d\:4e0d\:4e86"]]],
      listMods[cfg]]];

   Print["==> \:542f\:52a8\:4e2d\:2026"];
   (* Linux 上补窗口环境；Windows / macOS 直接继承，免得丢 SystemRoot 之类的变量 *)
   proc = If[$osName === "linux",
     StartProcess[cmd,
      ProcessEnvironment -> <|
        "HOME" -> $HomeDirectory,
        "PATH" -> "/usr/bin:/bin:/usr/local/bin",
        "DISPLAY" -> envOr["DISPLAY", ":0"],
        "WAYLAND_DISPLAY" -> envOr["WAYLAND_DISPLAY", ""],
        "XAUTHORITY" -> envOr["XAUTHORITY", ""],
        "XDG_RUNTIME_DIR" -> envOr["XDG_RUNTIME_DIR", ""]|>],
     StartProcess[cmd]];

   If[!MatchQ[proc, _ProcessObject],
    Print["[x] \:8fdb\:7a0b\:542f\:52a8\:5931\:8d25"]; Return[$Failed]];

   (* 启动后盯 10 秒日志，把关键输出转出来 *)
   waitSec = Quiet@Check[ToExpression[envOr["MCLAUNCH_WAIT", "10"]], 10];
   If[! NumberQ[waitSec], waitSec = 10];
   deadline = AbsoluteTime[] + waitSec;
   While[AbsoluteTime[] < deadline,
    line = Quiet@Check[TimeConstrained[ReadLine[proc], 0.3, $noData], $noData];
    eline = Quiet@Check[TimeConstrained[ReadLine[proc["StandardError"]], 0.3, $noData], $noData];
    If[StringQ[eline] && StringTrim[eline] =!= "", Print["  ! ", eline]];
    If[StringQ[line],
     Which[
      StringContainsQ[line, "<![CDATA["],
       Print["  | ", First[StringCases[line, "<![CDATA[" ~~ x__ ~~ "]]>" :> x]]];
       printed++,
      StringMatchQ[line, WhitespaceCharacter ... ~~ "<" ~~ ___],
       Null,
      True,
       Print["  | ", line]; printed++]];
    If[Quiet@ProcessStatus[proc] =!= "Running", Break[]]];

   Print["==> \:8f93\:51fa\:884c\:6570: ", printed, "   \:8fdb\:7a0b\:72b6\:6001: ", Quiet@ProcessStatus[proc]];
   proc];

interactive[]

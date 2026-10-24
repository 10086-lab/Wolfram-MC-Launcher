#!/usr/bin/env wolframscript
(* ==================================================================
   Wolfram Minecraft Launcher  ——  纯 Wolfram 语言实现
   ------------------------------------------------------------------
   直接运行进入交互菜单：改版本 / 玩家名 / 内存 / 窗口大小，
   按 5 启动，q 退出。不读命令行参数。
   ================================================================== *)

$mcHome      = FileNameJoin[{$HomeDirectory, ".minecraft"}];
$mcVersions  = FileNameJoin[{$mcHome, "versions"}];
$mcLibs      = FileNameJoin[{$mcHome, "libraries"}];
$mcAssets    = FileNameJoin[{$mcHome, "assets"}];
$manifestUrl = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

$javaCandidates = {
   "/usr/lib/jvm/jdk-26.0.2-oracle-x64/bin/java",
   "/usr/lib/jvm/java-21-openjdk-amd64/bin/java"};

$features = <|
   "is_demo_user" -> False,
   "has_custom_resolution" -> True,
   "has_quick_plays_support" -> False,
   "is_quick_play_singleplayer" -> False,
   "is_quick_play_multiplayer" -> False,
   "is_quick_play_realms" -> False|>;

(* ---------------- 基础工具 ---------------- *)
ensureDir[p_] := (If[!DirectoryQ[p], CreateDirectory[p, CreateIntermediateDirectories -> True]]; p);

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
osMatches[os_Association] := Module[{n = Lookup[os, "name", None], a = Lookup[os, "arch", None]},
   And[n === None || n === "linux", a === None]];

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

(* ---------------- 路径换算 ---------------- *)
libRelPath[name_String] := Module[{p = StringSplit[name, ":"]},
   If[Length[p] < 3, Return[$Failed]];
   FileNameJoin[{StringReplace[p[[1]], "." -> "/"], p[[2]], p[[3]],
     p[[2]] <> "-" <> p[[3]] <> ".jar"}]];

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

pickJava[] := Module[{ok = Select[$javaCandidates, FileExistsQ]},
   If[ok === {}, $Failed, First[ok]]];

(* ---------------- 配置持久化 ---------------- *)
$cfgFile = FileNameJoin[{$mcHome, "wl-launcher.conf"}];
$cfgKeys = {"version", "user", "ram", "size", "jvm", "game", "account", "active"};

$defaultCfg = <|
   "version" -> Automatic, "user" -> "Steve", "ram" -> "4G",
   "size" -> "1280x720", "jvm" -> "", "game" -> "",
   "account" -> "offline", "active" -> ""|>;

loadCfg[] := Module[{lines, pairs, cfg},
   If[! FileExistsQ[$cfgFile], Return[$defaultCfg]];
   lines = Select[Import[$cfgFile, "Lines"],
     StringContainsQ[#, "="] && ! StringStartsQ[StringTrim[#], "#"] &];
   pairs = DeleteCases[
     Function[l, With[{q = StringSplit[l, "=", 2]},
        If[Length[q] === 2, StringTrim[q[[1]]] -> StringTrim[q[[2]]],
         Missing["x"]]]] /@ lines, _Missing];
   cfg = Merge[{KeyTake[$defaultCfg, $cfgKeys],
      KeyTake[Association[pairs], $cfgKeys]}, Last];
   If[cfg["version"] === "", cfg["version"] = Automatic];
   cfg];

saveCfg[cfg_] := Module[{lines},
   lines = Function[k, k <> "=" <> Replace[cfg[k], Automatic -> ""]] /@ $cfgKeys;
   Export[$cfgFile, StringRiffle[lines, "\n"] <> "\n", "Text"]];
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
   RunProcess[{"chmod", "600", $acctFile}];);

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
localVersions[] := Module[{names},
   If[! DirectoryQ[$mcVersions], Return[{}]];
   names = FileNameTake /@ Quiet@Check[FileNames[$mcVersions <> "/*"], {}];
   Sort[Select[names,
     FileExistsQ[FileNameJoin[{$mcVersions, #, # <> ".json"}]] &]]];

dirBytes[dir_String] := Module[{r},
   If[! DirectoryQ[dir], Return[0]];
   r = Quiet@Check[RunProcess[{"du", "-sb", dir}, "StandardOutput"], ""];
   If[StringQ[r] && StringContainsQ[r, "\t"],
    Quiet@Check[ToExpression@First@StringSplit[StringTrim[r], "\t"], 0], 0]];

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
   Print["  \:7528 du \:7edf\:8ba1\:ff0c\:7a0d\:7b49\:4e00\:4e0b\:2026"];
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
     "1", cfg = editCfg[cfg, "version"],
     "2", cfg = editCfg[cfg, "user"],
     "3", cfg = editCfg[cfg, "ram"],
     "4", cfg = editCfg[cfg, "size"],
     "5", cfg = editCfg[cfg, "jvm"],
     "6", cfg = editCfg[cfg, "game"],
     "7", cfg = acctMenu[cfg],
     "8", cfg = pickLocal[cfg],
     "9", downloadAsk[cfg],
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
   RunProcess[{"chmod", "600", $tokenFile}];
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
   RunProcess[{"chmod", "600", $tokenFile}];
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

downloadAsk[cfg_] := Module[{c, r},
   Print["  \:8981\:4e0b\:54ea\:4e2a\:7248\:672c\:ff1f\:56de\:8f66\:53d6\:6d88\:ff0c\:8f93 ? \:5217\:53ef\:9009"];
   c = askLine["  \:7248\:672c > "];
   Which[
    c === $Failed || c === "", Null,
    c === "?", printVersions[],
    True,
     r = run[Join[cfg, <|"version" -> c|>], "download"];
     If[AssociationQ[r],
      Print["==> ", r["id"], " \:88c5\:597d\:4e86\:ff1a", r["libs"], " \:4e2a\:5e93\:3001",
       r["objs"], " \:4e2a\:8d44\:6e90"]]]];

(* ---------------- 主流程 ---------------- *)
run[cfg_Association, mode_String : "launch"] := Module[{
   manifest, target, verJson, localJson, id, java, cp, nativesDir, clientJar,
   authName, authUuid, authToken, authType,
   libEntries, libPaths, sown, art, rel, dest, jvmArgs, gameArgs, natJars,
   cmd, proc, line, n = 0, vars, logCfg, logPath, logArg, ai, aif,
   aIdx, objs2, assetRoot, missing, n2, missMB,
   deadline, sz, printed = 0},
   manifest = getJson[$manifestUrl];

   id = If[cfg["version"] === Automatic,
     If[manifest === $Failed,
      Print["[x] \:62ff\:4e0d\:5230\:7248\:672c\:6e05\:5355\:ff0c\:68c0\:67e5\:7f51\:7edc\:ff08\:4e5f\:53ef\:4ee5\:5148\:6309 7 \:9009\:672c\:5730\:7248\:672c\:ff09"];
      Return[$Failed],
      manifest["latest", "release"]],
     cfg["version"]];

   localJson = FileNameJoin[{$mcVersions, id, id <> ".json"}];
   verJson = If[FileExistsQ[localJson],
     Print["==> Minecraft ", id, "  (\:672c\:5730\:6e05\:5355)"];
     Quiet@Check[Import[localJson, "RawJSON"], $Failed],
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

   java = pickJava[];
   If[java === $Failed, Print["[x] \:627e\:4e0d\:5230\:53ef\:7528\:7684 Java"]; Return[$Failed]];
   Print["    Java   : ", java];
   Print["    \:4e3b\:7c7b   : ", verJson["mainClass"]];

   (* --- client.jar --- *)
   clientJar = FileNameJoin[{$mcVersions, id, id <> ".jar"}];
   ensureDir[DirectoryName[clientJar]];
   art = verJson["downloads", "client"];
   Print["    client : ", IntegerPart[art["size"]/1024/1024], " MB"];
   If[dl[art["url"], clientJar, art["size"]] === $Failed,
    Print["[x] client.jar \:4e0b\:8f7d\:5931\:8d25"]; Return[$Failed]];

   (* --- libraries --- *)
   libEntries = Select[verJson["libraries"], libAllowed];
   Print["    \:5e93     : ", Length[libEntries], " \:4e2a\:ff08Linux \:53ef\:7528\:ff09"];
   natJars = {};
   sown = Reap[
      Do[
       art = Lookup[lib["downloads"], "artifact", None];
       If[art === None, Continue[]];
       (* 关键：用清单给的 path。同一 Maven 坐标可能有主 jar+多个 natives 变体，
          自己按 name 推算会把它们算成同一个文件互相覆盖 *)
       rel = Lookup[art, "path", None];
       If[rel === None, rel = libRelPath[lib["name"]]];
       If[rel === $Failed || rel === None, Continue[]];
       dest = FileNameJoin[{$mcLibs, rel}];
       If[dl[art["url"], dest, art["size"]] =!= $Failed,
        Sow[dest]; n++;
        If[StringContainsQ[lib["name"], ":natives-"], AppendTo[natJars, dest]];
        If[Mod[n, 10] === 0, showProg["\:5e93\:6587\:4ef6", n, Length[libEntries]]]]
       , {lib, libEntries}]][[2]];
   endProg[];
   libPaths = DeleteDuplicates@If[sown === {}, {}, First[sown]];
   Print["    \:5c31\:7eea   : ", Length[libPaths], " \:4e2a\:5e93"];

   (* --- natives 目录（26.x 无需解压） --- *)
   nativesDir = FileNameJoin[{$mcHome, "natives", id}];
   ensureDir[nativesDir];
   Scan[Quiet@Check[ExtractArchive[#, nativesDir], Null] &, natJars];
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
    ParallelMap[
     Function[ob,
      Module[{p, u},
       p = FileNameJoin[{assetRoot, StringTake[ob["hash"], 2], ob["hash"]}];
       If[! DirectoryExistsQ[DirectoryName[p]],
        CreateDirectory[DirectoryName[p], CreateIntermediateDirectories -> True]];
       If[FileExistsQ[p] && FileByteCount[p] === ob["size"], Return[1]];
       u = "https://resources.download.minecraft.net/" <>
         StringTake[ob["hash"], 2] <> "/" <> ob["hash"];
       Quiet@Check[URLDownload[u, p, TimeConstraint -> 120], Null];
       If[FileExistsQ[p] && FileByteCount[p] === ob["size"], 1, 0]]],
     missing, Method -> "CoarsestGrained"],
    Print["    \:8d44\:6e90   : index ", ai["id"], "\:ff08", Length[objs2], " \:9879\:ff0c\:5df2\:9f50\:5168\:ff09"]];

   If[mode === "download",
    Print["==> \:5168\:90e8\:4e0b\:597d\:4e86\:ff1a", Length[libPaths], " \:4e2a\:5e93\:3001",
     Length[objs2], " \:4e2a\:8d44\:6e90"];
    Return[<|"id" -> id, "libs" -> Length[libPaths],
      "objs" -> Length[objs2]|>]];

   authName = $auth["name"]; authUuid = $auth["uuid"];
   authToken = $auth["token"]; authType = $auth["type"];

   (* --- 组装命令行 --- *)
   sz = StringSplit[cfg["size"], "x"];
   cp = StringRiffle[Prepend[libPaths, clientJar], ":"];
   vars = <|
     "$" <> "{natives_directory}" -> nativesDir,
     "$" <> "{classpath}" -> cp,
     "$" <> "{launcher_name}" -> "WolframMC",
     "$" <> "{launcher_version}" -> "1.0",
     "$" <> "{version_name}" -> id,
     "$" <> "{game_directory}" -> $mcHome,
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

   jvmArgs = DeleteCases[Flatten[{fillVars[#, vars] & /@ expandArgs[verJson["arguments", "jvm"]],
       logArg}], _Nothing | _Missing];
   gameArgs = cleanArgs[fillVars[#, vars] & /@ expandArgs[verJson["arguments", "game"]]];

   cmd = Join[{java, "-Xmx" <> cfg["ram"], "-Xms1G"}, jvmArgs,
     extraArgs[cfg["jvm"]], {verJson["mainClass"]}, gameArgs,
     extraArgs[cfg["game"]]];

   Print["==> Java: ", java];
   Print["==> JVM \:53c2\:6570 ", Length[jvmArgs], " \:6761\:ff0c\:6e38\:620f\:53c2\:6570 ", Length[gameArgs], " \:6761"];

   Print["==> \:542f\:52a8\:4e2d\:2026"];
   proc = StartProcess[cmd,
     ProcessEnvironment -> <|
       "HOME" -> $HomeDirectory,
       "PATH" -> "/usr/bin:/bin:/usr/local/bin",
       "DISPLAY" -> Replace[Environment["DISPLAY"], _Missing -> ":0"],
       "WAYLAND_DISPLAY" -> Replace[Environment["WAYLAND_DISPLAY"], _Missing -> ""],
       "XAUTHORITY" -> Replace[Environment["XAUTHORITY"], _Missing -> ""],
       "XDG_RUNTIME_DIR" -> Replace[Environment["XDG_RUNTIME_DIR"], _Missing -> ""]|>];

   If[!MatchQ[proc, _ProcessObject],
    Print["[x] \:8fdb\:7a0b\:542f\:52a8\:5931\:8d25"]; Return[$Failed]];

   (* 启动后盯 10 秒日志，把关键输出转出来 *)
   deadline = AbsoluteTime[] + 10;
   While[AbsoluteTime[] < deadline,
    line = Quiet@Check[TimeConstrained[ReadLine[proc], 0.3, $noData], $noData];
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

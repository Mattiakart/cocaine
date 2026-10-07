#!/usr/bin/env python3 -I
"""App Intents metadata without Xcode, for `./build.sh --app-intents` ONLY (never a release; see docs/maintainers/app-intents.md).

  gen-appintents-metadata.py generate <file.swiftconstvalues> <out dir> [--module Cocaine]
      Reads the compiler's const values (swiftc -Xfrontend -emit-const-values-path, with tools/appintents-protocols.json) and
      writes <out dir>/Metadata.appintents/{extract.actionsdata, version.json}: the plain-JSON format Xcode's
      appintentsmetadataprocessor writes (version 3.0, read the same from macOS 14 to 27), for the subset Cocaine uses: AppIntent
      structs with literal titles, Bool/Int/Double/String/Date parameters, one AppEnum, ReturnsValue<Bool|Int|String>.
      Anything else (macros, entities, queries, App Shortcuts phrases) is refused rather than guessed.
  gen-appintents-metadata.py check <Metadata.appintents dir> [<binary>]
      Checks the files against that schema: both parse, the keys every action/parameter/enum needs, unique identifiers,
      enums referenced exist, and (with a binary) every mangledTypeName has its type descriptor ($s…Mn) in every slice (nm).
      Exit 0 = good. Used by verify.sh in a temporary folder: nothing is installed or registered.
The format is private and undocumented (reverse-read from Apple's own apps' bundles); Apple may change it.
"""
import json, os, subprocess, sys

PRIMS = {"Swift.String": 0, "Swift.Bool": 1, "Swift.Int": 2, "Swift.Double": 7, "Foundation.Date": 8}


def fail(msg):
    print("gen-appintents-metadata: " + msg, file=sys.stderr)
    sys.exit(1)


def literal(v):
    """A RawLiteral argument's value, or None."""
    return v.get("value") if isinstance(v, dict) and v.get("valueKind") == "RawLiteral" else None


def arg(call, label):
    for a in (call or {}).get("arguments", []):
        if a.get("label") == label:
            return a
    return None


def unwrap(t):
    if t.startswith("Swift.Optional<") and t.endswith(">"):
        return t[len("Swift.Optional<"):-1], True
    return t, False


def value_type(t, enums):
    t, opt = unwrap(t)
    if t in PRIMS:
        return {"primitive": {"wrapper": {"typeIdentifier": PRIMS[t]}}}, opt, t
    if t in enums:
        return {"linkEnumeration": {"wrapper": {"identifier": enums[t]}}}, opt, t
    fail("parameter type %s isn't supported by this generator" % t)


def title(s):
    return {"key": s, "alternatives": []}


def generate(src, out, module):
    data = json.load(open(src, encoding="utf-8"))
    enums, actions, enum_list = {}, {}, []
    for t in data:
        if "AppIntents.AppEnum" in t.get("conformances", []):
            name = t["typeName"].split(".")[-1]
            enums[t["typeName"]] = name
            props = {p["label"]: p for p in t.get("properties", [])}
            reps = props.get("caseDisplayRepresentations", {}).get("value") or []
            shown = {}
            for kv in reps:
                k = kv["key"]["value"]["name"]
                shown[k] = literal(kv["value"]) or k
            cases = [c["name"] for c in t.get("cases", [])] or list(shown)
            if not cases:
                fail("enum %s has no cases" % name)
            enum_list.append({
                "identifier": name, "mangledTypeName": t["mangledTypeName"], "mangledTypeNameV2": t["mangledTypeName"],
                "fullyQualifiedTypeName": t["typeName"],
                "displayTypeName": title(literal(props.get("typeDisplayRepresentation")) or name),
                "cases": [{"identifier": c, "displayRepresentation": {"title": title(shown.get(c, c))}} for c in cases],
                "systemProtocols": [], "assistantDefinedSchemas": [],
            })
    for t in data:
        if "AppIntents.AppIntent" not in t.get("conformances", []):
            continue
        name = t["typeName"].split(".")[-1]
        props = {p["label"]: p for p in t.get("properties", [])}
        ttl = literal(props.get("title"))
        if ttl is None:
            fail("%s: its title must be a string literal" % name)
        desc = literal(props.get("description")) or ""
        open_app = literal(props.get("openAppWhenRun")) == "true"
        params = []
        for p in t.get("properties", []):
            if not p["label"].startswith("_") or p.get("valueKind") != "InitCall":
                continue
            call = p["value"]
            ptype = call["type"]
            if not ptype.startswith("AppIntents.IntentParameter<"):
                continue
            inner = ptype[len("AppIntents.IntentParameter<"):-1]
            vt, opt, base = value_type(inner, enums)
            meta = []
            d = arg(call, "default")
            if d is not None and d.get("valueKind") == "RawLiteral":
                v = d["value"]
                meta.append(["LNValueTypeSpecificMetadataKeyDefaultValue",
                             {"bool": {"wrapper": v == "true"}} if base == "Swift.Bool" else {"number": {"wrapper": float(v)}}
                             if base in ("Swift.Int", "Swift.Double") else {"string": {"wrapper": v}}])
            elif d is not None and d.get("valueKind") == "Enum":
                meta.append(["LNValueTypeSpecificMetadataKeyDefaultValue", {"string": {"wrapper": d["value"]["name"]}}])
            dn = arg(call, "displayName")
            if dn and dn.get("valueKind") == "InitCall":
                tv, fv = literal(arg(dn["value"], "true")), literal(arg(dn["value"], "false"))
                meta += [["LNValueTypeMetadataKeyBoolTrueDisplayName", {"string": {"wrapper": tv}}],
                         ["LNValueTypeMetadataKeyBoolFalseDisplayName", {"string": {"wrapper": fv}}]]
            rng = arg(call, "inclusiveRange")
            if rng and rng.get("valueKind") == "Tuple":
                lo, hi = (literal(x) for x in rng["value"])
                meta += [["LNValueTypeSpecificMetadataKeyMinimumValue", {"number": {"wrapper": float(lo)}}],
                         ["LNValueTypeSpecificMetadataKeyMaximumValue", {"number": {"wrapper": float(hi)}}]]
            ptitle = literal(arg(call, "title"))
            if ptitle is None:
                fail("%s.%s: its title must be a string literal" % (name, p["label"]))
            params.append({
                "name": p["label"][1:], "title": title(ptitle), "isOptional": opt, "capabilities": 0,
                "dynamicOptionsSupport": 0, "inputConnectionBehavior": 0, "isInput": False, "valueType": vt,
                "resolvableInputTypes": [vt], "typeSpecificMetadata": [x for pair in meta for x in pair],
            })
        result = next((a for a in t.get("associatedTypeAliases", []) if a.get("typeAliasName") == "PerformResult"), {})
        rname = result.get("substitutedTypeName", "")
        output = None
        if "ReturnsValue<" in rname:
            inner = rname.split("ReturnsValue<", 1)[1].rsplit(">", 1)[0]
            output = value_type(inner, enums)[0]
        actions[name] = {
            "identifier": name, "mangledTypeName": t["mangledTypeName"], "mangledTypeNameV2": t["mangledTypeName"],
            "fullyQualifiedTypeName": t["typeName"], "title": title(ttl),
            "descriptionMetadata": {"descriptionText": title(desc), "searchKeywords": []},
            "openAppWhenRun": open_app, "outputType": output, "outputFlags": 0 if output is None else 1,
            "parameters": params,
            "actionConfiguration": {"actionSummary": {"formatString": title(ttl)}},
            "availabilityAnnotations": {}, "isDiscoverable": True, "visibilityMetadata": {"isDiscoverable": True},
            "supportedModes": 0, "presentationStyle": 0, "authenticationPolicy": 0,
            "systemProtocols": [], "systemProtocolDefaults": {}, "assistantDefinedSchemas": [], "assistantDefinedSchemaTraits": [],
        }
        if output is None:
            del actions[name]["outputType"]
    if not actions:
        fail("no AppIntent found in %s (built without -D COCAINE_APP_INTENTS?)" % src)
    extract = {
        "actions": actions, "enums": enum_list, "entities": {}, "queries": {}, "autoShortcuts": [],
        "autoShortcutProviderMangledName": "", "shortcutTileColor": 14, "assistantIntents": [], "assistantEntities": [],
        "negativePhrases": [], "assistantIntentNegativePhrases": [], "generator": {"name": "cocaine-gen-appintents-metadata", "version": "1"},
        "version": 1,
    }
    d = os.path.join(out, "Metadata.appintents")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "extract.actionsdata"), "w", encoding="utf-8") as f:
        json.dump(extract, f, indent=1, sort_keys=True)
    with open(os.path.join(d, "version.json"), "w", encoding="utf-8") as f:
        json.dump({"toolsVersion": "*", "version": "3.0"}, f)
    print("wrote %s: %d action(s), %d enum(s)" % (d, len(actions), len(enum_list)))


ACTION_KEYS = ["identifier", "mangledTypeName", "mangledTypeNameV2", "fullyQualifiedTypeName", "title", "descriptionMetadata",
               "openAppWhenRun", "outputFlags", "parameters", "actionConfiguration", "availabilityAnnotations", "isDiscoverable",
               "visibilityMetadata", "supportedModes", "presentationStyle", "authenticationPolicy"]
PARAM_KEYS = ["name", "title", "isOptional", "capabilities", "dynamicOptionsSupport", "inputConnectionBehavior", "isInput",
              "valueType", "resolvableInputTypes", "typeSpecificMetadata"]
TOP_KEYS = ["actions", "enums", "entities", "queries", "autoShortcuts", "autoShortcutProviderMangledName", "shortcutTileColor",
            "assistantIntents", "assistantEntities", "negativePhrases", "assistantIntentNegativePhrases", "generator", "version"]


def check(d, binary=None):
    problems = []
    try:
        v = json.load(open(os.path.join(d, "version.json"), encoding="utf-8"))
        if v.get("version") != "3.0" or "toolsVersion" not in v:
            problems.append("version.json: version 3.0 and toolsVersion expected")
    except Exception as e:
        problems.append("version.json: %s" % e)
    try:
        x = json.load(open(os.path.join(d, "extract.actionsdata"), encoding="utf-8"))
    except Exception as e:
        print("FAIL  extract.actionsdata: %s" % e)
        return 1
    problems += ["missing top key %s" % k for k in TOP_KEYS if k not in x]
    enums = {e.get("identifier") for e in x.get("enums", [])}
    for e in x.get("enums", []):
        if not e.get("cases") or not e.get("mangledTypeName"):
            problems.append("enum %s: cases and mangledTypeName needed" % e.get("identifier"))
    mangled = []
    for name, a in (x.get("actions") or {}).items():
        problems += ["%s: missing %s" % (name, k) for k in ACTION_KEYS if k not in a]
        if a.get("identifier") != name:
            problems.append("%s: identifier differs from its key" % name)
        mangled.append(a.get("mangledTypeName", ""))
        names = [p.get("name") for p in a.get("parameters", [])]
        if len(set(names)) != len(names):
            problems.append("%s: parameter names repeated" % name)
        for p in a.get("parameters", []):
            problems += ["%s.%s: missing %s" % (name, p.get("name"), k) for k in PARAM_KEYS if k not in p]
            vt = p.get("valueType", {})
            if "linkEnumeration" in vt and vt["linkEnumeration"]["wrapper"]["identifier"] not in enums:
                problems.append("%s.%s: unknown enum" % (name, p.get("name")))
            if "primitive" in vt and vt["primitive"]["wrapper"].get("typeIdentifier") not in PRIMS.values():
                problems.append("%s.%s: unknown primitive" % (name, p.get("name")))
    if not x.get("actions"):
        problems.append("no actions")
    mangled += [e.get("mangledTypeName", "") for e in x.get("enums", [])]
    if binary:
        archs = subprocess.run(["/usr/bin/lipo", "-archs", binary], capture_output=True, text=True).stdout.split() or [None]
        for arch in archs:
            cmd = ["/usr/bin/nm", "-gU"] + (["-arch", arch] if arch else []) + [binary]
            syms = set(l.split()[-1] for l in subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines() if l.strip())
            syms |= set(l.split()[-1] for l in subprocess.run(cmd[:1] + cmd[2:], capture_output=True, text=True).stdout.splitlines() if l.strip())
            for m in mangled:
                if "_$s%sMn" % m not in syms and "$s%sMn" % m not in syms:
                    problems.append("%s: no type descriptor for %s" % (arch or "binary", m))
    for p in problems:
        print("FAIL  " + p)
    if not problems:
        print("PASS  App Intents metadata: %d action(s), %d enum(s)%s" % (len(x.get("actions", {})), len(x.get("enums", [])),
                                                                          ", every type in the binary" if binary else ""))
    return 1 if problems else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "generate":
        generate(a[1], a[2], a[4] if len(a) > 4 and a[3] == "--module" else "Cocaine")
    elif len(a) in (2, 3) and a[0] == "check":
        sys.exit(check(a[1], a[2] if len(a) == 3 else None))
    else:
        print(__doc__)
        sys.exit(64)

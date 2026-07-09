#Requires AutoHotkey v2.0
; ============================================================
;  Json.ahk — minimal JSON encode/parse for the AI backend.
;
;  JsonEscape(s)  -> escaped string CONTENT (no surrounding quotes),
;                    for building request bodies by hand.
;  JsonParse(s)   -> Map (objects) / Array (arrays) / String / Number,
;                    true/false -> 1/0, null -> "".
;                    Throws Error() on malformed input.
;
;  Deliberately small: no serializer for objects (requests are built
;  with JsonEscape), no comments/trailing-comma tolerance. Keys are
;  case-sensitive (Map default), matching real JSON semantics.
; ============================================================

; Escape one string for embedding inside a JSON string literal.
JsonEscape(s) {
    out := ""
    Loop Parse s {
        c := A_LoopField
        switch c, true {
            case '"':  out .= '\"'
            case "\":  out .= "\\"
            case "`n": out .= "\n"
            case "`r": out .= "\r"
            case "`t": out .= "\t"
            case "`b": out .= "\b"
            case "`f": out .= "\f"
            default:
                out .= (Ord(c) < 0x20) ? Format("\u{:04x}", Ord(c)) : c
        }
    }
    return out
}

JsonParse(s) {
    pos := 1
    v := JsonParseValue(s, &pos)
    JsonSkipWs(s, &pos)
    if (pos <= StrLen(s))
        throw Error("JSON: unexpected trailing characters at position " pos)
    return v
}

JsonSkipWs(s, &pos) {
    while (pos <= StrLen(s)) {
        c := SubStr(s, pos, 1)
        if (c != " " && c != "`t" && c != "`n" && c != "`r")
            break
        pos += 1
    }
}

JsonParseValue(s, &pos) {
    JsonSkipWs(s, &pos)
    c := SubStr(s, pos, 1)
    if (c = "")
        throw Error("JSON: unexpected end of input")
    if (c = "{")
        return JsonParseObject(s, &pos)
    if (c = "[")
        return JsonParseArray(s, &pos)
    if (c = '"')
        return JsonParseString(s, &pos)
    if (SubStr(s, pos, 4) == "true") {
        pos += 4
        return true
    }
    if (SubStr(s, pos, 5) == "false") {
        pos += 5
        return false
    }
    if (SubStr(s, pos, 4) == "null") {
        pos += 4
        return ""
    }
    if (RegExMatch(s, "-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?", &m, pos) && m.Pos = pos) {
        pos += StrLen(m[0])
        return Number(m[0])
    }
    throw Error("JSON: unexpected character '" c "' at position " pos)
}

JsonParseObject(s, &pos) {   ; pos is at the "{"
    obj := Map()
    pos += 1
    JsonSkipWs(s, &pos)
    if (SubStr(s, pos, 1) = "}") {
        pos += 1
        return obj
    }
    loop {
        JsonSkipWs(s, &pos)
        if (SubStr(s, pos, 1) != '"')
            throw Error("JSON: expected a quoted key at position " pos)
        k := JsonParseString(s, &pos)
        JsonSkipWs(s, &pos)
        if (SubStr(s, pos, 1) != ":")
            throw Error("JSON: expected ':' at position " pos)
        pos += 1
        obj[k] := JsonParseValue(s, &pos)
        JsonSkipWs(s, &pos)
        c := SubStr(s, pos, 1)
        pos += 1
        if (c = ",")
            continue
        if (c = "}")
            return obj
        throw Error("JSON: expected ',' or '}' at position " (pos - 1))
    }
}

JsonParseArray(s, &pos) {   ; pos is at the "["
    arr := []
    pos += 1
    JsonSkipWs(s, &pos)
    if (SubStr(s, pos, 1) = "]") {
        pos += 1
        return arr
    }
    loop {
        arr.Push(JsonParseValue(s, &pos))
        JsonSkipWs(s, &pos)
        c := SubStr(s, pos, 1)
        pos += 1
        if (c = ",")
            continue
        if (c = "]")
            return arr
        throw Error("JSON: expected ',' or ']' at position " (pos - 1))
    }
}

JsonParseString(s, &pos) {   ; pos is at the opening quote
    pos += 1
    out := ""
    loop {
        if (pos > StrLen(s))
            throw Error("JSON: unterminated string")
        c := SubStr(s, pos, 1)
        if (c = '"') {
            pos += 1
            return out
        }
        if (c != "\") {
            out .= c
            pos += 1
            continue
        }
        e := SubStr(s, pos + 1, 1)
        switch e, true {
            case '"':  out .= '"'
            case "\":  out .= "\"
            case "/":  out .= "/"
            case "b":  out .= "`b"
            case "f":  out .= "`f"
            case "n":  out .= "`n"
            case "r":  out .= "`r"
            case "t":  out .= "`t"
            case "u":
                hex := SubStr(s, pos + 2, 4)
                if !(hex ~= "^[0-9a-fA-F]{4}$")
                    throw Error("JSON: bad \u escape at position " pos)
                cp := Integer("0x" hex)
                pos += 6                          ; past \uXXXX
                ; A high surrogate followed by a \u-escaped low surrogate is
                ; one supplementary character (e.g. an emoji) — combine them.
                if (cp >= 0xD800 && cp <= 0xDBFF && SubStr(s, pos, 2) = "\u") {
                    hex2 := SubStr(s, pos + 2, 4)
                    if (hex2 ~= "^[0-9a-fA-F]{4}$") {
                        lo := Integer("0x" hex2)
                        if (lo >= 0xDC00 && lo <= 0xDFFF) {
                            cp := 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                            pos += 6
                        }
                    }
                }
                out .= Chr(cp)
                continue
            default:
                throw Error("JSON: bad escape '\" e "' at position " pos)
        }
        pos += 2
    }
}

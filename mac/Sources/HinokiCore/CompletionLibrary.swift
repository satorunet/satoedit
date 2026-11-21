import Foundation

/// 言語ごとによく使う関数・タグ・プロパティ (入力補完の元)
public enum CompletionLibrary {
    /// 言語の名前 (LanguageProfile.name) から、組み込みの候補
    public static func items(for language: String?) -> [Completion.Item] {
        guard let language = language else { return [] }
        if let cached = cache[language] { return cached }
        let list: [Completion.Item]
        switch language {
        case "JavaScript / TypeScript": list = fns(javascript)
        case "PHP": list = fns(php)
        case "Python": list = fns(python)
        case "Swift": list = fns(swift)
        case "Go": list = fns(go)
        case "Ruby": list = fns(ruby)
        case "CSS": list = cssProperties.map { Completion.Item(label: $0, kind: .property) }
        case "HTML / XML":
            list = htmlTags.map { Completion.Item(label: $0, kind: .tag) }
                + htmlAttributes.map { Completion.Item(label: $0, kind: .property) }
        default: list = []
        }
        cache[language] = list
        return list
    }

    private static var cache: [String: [Completion.Item]] = [:]

    private static func fns(_ text: String) -> [Completion.Item] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { Completion.Item.function($0) }
    }

    /// 閉じタグを付けないタグ
    public static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]

    static let htmlTags = """
    a abbr address article aside audio b blockquote body br button canvas caption code dd details dialog div dl dt em \
    fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hr html i iframe img input label legend li link \
    main meta nav noscript ol optgroup option p picture pre script section select small source span strong style sub \
    summary sup table tbody td template textarea tfoot th thead title tr u ul video
    """.split(separator: " ").map(String.init)

    static let htmlAttributes = """
    class id style href src alt title type name value placeholder action method target rel charset content width height \
    onclick onchange onsubmit disabled checked selected readonly required autocomplete loading lang
    """.split(separator: " ").map(String.init)

    static let cssProperties = """
    align-items align-content align-self animation background background-color background-image background-position \
    background-repeat background-size border border-bottom border-collapse border-color border-left border-radius \
    border-right border-style border-top border-width bottom box-shadow box-sizing clear color column-gap content cursor \
    display flex flex-basis flex-direction flex-grow flex-shrink flex-wrap float font font-family font-size font-style \
    font-weight gap grid grid-area grid-column grid-row grid-template-areas grid-template-columns grid-template-rows height \
    justify-content justify-items left letter-spacing line-height list-style margin margin-bottom margin-left margin-right \
    margin-top max-height max-width min-height min-width object-fit opacity order outline overflow overflow-x overflow-y \
    padding padding-bottom padding-left padding-right padding-top pointer-events position right row-gap text-align \
    text-decoration text-overflow text-shadow text-transform top transform transition user-select vertical-align \
    visibility white-space width word-break z-index
    """.split(separator: " ").map(String.init)

    static let javascript = """
    console.log(...data)
    console.error(...data)
    console.warn(...data)
    alert(message)
    confirm(message)
    prompt(message, default)
    setTimeout(handler, timeout)
    setInterval(handler, timeout)
    clearTimeout(id)
    clearInterval(id)
    requestAnimationFrame(callback)
    fetch(input, init)
    parseInt(string, radix)
    parseFloat(string)
    isNaN(number)
    encodeURIComponent(uriComponent)
    decodeURIComponent(encodedURIComponent)
    addEventListener(type, listener, options)
    removeEventListener(type, listener, options)
    querySelector(selectors)
    querySelectorAll(selectors)
    getElementById(elementId)
    getElementsByClassName(classNames)
    getElementsByTagName(qualifiedName)
    createElement(tagName, options)
    appendChild(node)
    removeChild(child)
    insertBefore(node, child)
    setAttribute(name, value)
    getAttribute(name)
    removeAttribute(name)
    preventDefault()
    stopPropagation()
    push(...items)
    pop()
    shift()
    unshift(...items)
    slice(start, end)
    splice(start, deleteCount, ...items)
    concat(...items)
    join(separator)
    reverse()
    sort(compareFn)
    indexOf(searchElement, fromIndex)
    includes(searchElement, fromIndex)
    find(predicate)
    findIndex(predicate)
    filter(predicate)
    map(callbackfn)
    forEach(callbackfn)
    reduce(callbackfn, initialValue)
    some(predicate)
    every(predicate)
    split(separator, limit)
    replace(searchValue, replaceValue)
    replaceAll(searchValue, replaceValue)
    trim()
    toLowerCase()
    toUpperCase()
    startsWith(searchString, position)
    endsWith(searchString, endPosition)
    padStart(maxLength, fillString)
    substring(start, end)
    toFixed(fractionDigits)
    toString()
    then(onfulfilled, onrejected)
    catch(onrejected)
    finally(onfinally)
    JSON.stringify(value, replacer, space)
    JSON.parse(text, reviver)
    Object.keys(o)
    Object.values(o)
    Object.entries(o)
    Object.assign(target, ...sources)
    Array.from(arrayLike, mapfn)
    Array.isArray(arg)
    Math.floor(x)
    Math.ceil(x)
    Math.round(x)
    Math.random()
    Math.max(...values)
    Math.min(...values)
    Math.abs(x)
    Promise.all(values)
    """

    static let php = """
    echo(string)
    print_r(value, return)
    var_dump(value)
    isset(var)
    empty(var)
    unset(var)
    count(value)
    strlen(string)
    mb_strlen(string, encoding)
    substr(string, offset, length)
    mb_substr(string, start, length, encoding)
    strpos(haystack, needle, offset)
    mb_strpos(haystack, needle, offset, encoding)
    str_replace(search, replace, subject)
    str_contains(haystack, needle)
    str_starts_with(haystack, needle)
    preg_match(pattern, subject, matches)
    preg_match_all(pattern, subject, matches)
    preg_replace(pattern, replacement, subject)
    preg_split(pattern, subject, limit)
    explode(separator, string, limit)
    implode(separator, array)
    trim(string, characters)
    rtrim(string, characters)
    ltrim(string, characters)
    strtolower(string)
    strtoupper(string)
    ucfirst(string)
    sprintf(format, ...values)
    printf(format, ...values)
    number_format(num, decimals, decimal_separator, thousands_separator)
    htmlspecialchars(string, flags, encoding)
    nl2br(string)
    strip_tags(string, allowed_tags)
    urlencode(string)
    json_encode(value, flags)
    json_decode(json, associative)
    array_keys(array)
    array_values(array)
    array_merge(...arrays)
    array_map(callback, array)
    array_filter(array, callback)
    array_push(array, ...values)
    array_pop(array)
    array_shift(array)
    array_slice(array, offset, length)
    array_search(needle, haystack)
    array_unique(array)
    array_reverse(array)
    array_key_exists(key, array)
    in_array(needle, haystack, strict)
    sort(array)
    usort(array, callback)
    ksort(array)
    is_array(value)
    is_numeric(value)
    is_null(value)
    intval(value)
    floatval(value)
    date(format, timestamp)
    time()
    strtotime(datetime)
    mktime(hour, minute, second, month, day, year)
    file_get_contents(filename)
    file_put_contents(filename, data, flags)
    file_exists(filename)
    is_file(filename)
    is_dir(filename)
    mkdir(directory, permissions, recursive)
    unlink(filename)
    fopen(filename, mode)
    fclose(stream)
    fgets(stream, length)
    fwrite(stream, data)
    header(header)
    session_start()
    setcookie(name, value, expires, path)
    require_once(file)
    include_once(file)
    define(constant_name, value)
    function_exists(function)
    mb_convert_encoding(string, to_encoding, from_encoding)
    filter_input(type, var_name, filter)
    password_hash(password, algo)
    password_verify(password, hash)
    """

    static let python = """
    print(*values, sep, end)
    len(obj)
    range(start, stop, step)
    enumerate(iterable, start)
    zip(*iterables)
    open(file, mode, encoding)
    input(prompt)
    int(x)
    str(object)
    float(x)
    list(iterable)
    dict(**kwargs)
    set(iterable)
    tuple(iterable)
    sorted(iterable, key, reverse)
    reversed(seq)
    sum(iterable, start)
    min(iterable)
    max(iterable)
    abs(x)
    round(number, ndigits)
    isinstance(obj, class_or_tuple)
    hasattr(obj, name)
    getattr(obj, name, default)
    setattr(obj, name, value)
    map(function, iterable)
    filter(function, iterable)
    any(iterable)
    all(iterable)
    super()
    append(object)
    extend(iterable)
    insert(index, object)
    remove(value)
    pop(index)
    get(key, default)
    items()
    keys()
    values()
    update(other)
    join(iterable)
    split(sep, maxsplit)
    strip(chars)
    replace(old, new, count)
    startswith(prefix)
    endswith(suffix)
    format(*args, **kwargs)
    lower()
    upper()
    """

    static let swift = """
    print(items, separator, terminator)
    append(newElement)
    contains(element)
    filter(isIncluded)
    map(transform)
    compactMap(transform)
    reduce(initialResult, nextPartialResult)
    forEach(body)
    sorted(by)
    first(where)
    firstIndex(of)
    removeAll(where)
    insert(newElement, at)
    remove(at)
    joined(separator)
    split(separator)
    hasPrefix(prefix)
    hasSuffix(suffix)
    replacingOccurrences(of, with)
    trimmingCharacters(in)
    """

    static let go = """
    fmt.Println(a)
    fmt.Printf(format, a)
    fmt.Sprintf(format, a)
    fmt.Errorf(format, a)
    append(slice, elems)
    len(v)
    cap(v)
    make(t, size)
    delete(m, key)
    panic(v)
    strings.Split(s, sep)
    strings.Join(elems, sep)
    strings.Contains(s, substr)
    strings.TrimSpace(s)
    strconv.Itoa(i)
    strconv.Atoi(s)
    """

    static let ruby = """
    puts(obj)
    print(obj)
    require(name)
    each(block)
    map(block)
    select(block)
    reject(block)
    include?(obj)
    join(separator)
    split(pattern)
    gsub(pattern, replacement)
    """
}

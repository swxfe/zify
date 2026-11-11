import { check } from 'common';

export function validate_list_asset(text, limit, max_bytes) {
    // Assets preserve upstream's IP/CIDR, suffixes, Unicode and comments verbatim.
    // This is data copied to a fixed list path, never shell source or CLI arguments.
    check(type(text) == 'string' && length(text) <= max_bytes, 'слишком большой список в ассетов');
    check(index(text, '\x00') == -1 && !match(text, /[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]/),
        'управляющие байты в списке ассетов');
    // Search bounded byte windows in native code instead of interpreting every byte.
    // This preserves the byte limit for UTF-8 and never allocates a list of lines.
    let count = 0, size = length(text), nonblank = /[^ \t\r]/;
    for (let offset = 0; offset < size;) {
        let window = substr(text, offset, 1025), end = index(window, '\n');
        check(end != -1 || length(window) <= 1024, 'слишком длинная строка списка ассетов');
        let line = end == -1 ? window : substr(window, 0, end);
        if (match(line, nonblank)) count++;
        check(count <= limit, 'превышен лимит строк списка ассетов');
        offset += end == -1 ? length(window) : end + 1;
    }
    return true;
};

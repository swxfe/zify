import { equal, rejects, count } from '../support/assertions.uc';
import { validate_list_asset } from 'lists';

export function run() {
    equal(validate_list_asset('# package defaults\n127.0.0.0/8\n::1\nfc00::/7\nru\nрф\nexample.com\n', 8, 1024), true, 'asset preserves upstream mixed list formats');
    rejects(() => validate_list_asset('a\x00b', 8, 1024), 'asset rejects NUL bytes');
    rejects(() => validate_list_asset('a\nb\n', 1, 1024), 'asset list line limit');
    rejects(() => validate_list_asset('example.com', 8, 4), 'asset list byte limit');
    let wide_line = '';
    for (let i = 0; i < 512; i++) wide_line += 'я';
    equal(validate_list_asset(wide_line + '\n', 1, 4096), true, 'asset accepts exactly 1024 UTF-8 bytes');
    rejects(() => validate_list_asset(wide_line + 'x\n', 1, 4096), 'asset byte width is not a Unicode character count');
    equal(validate_list_asset(' \t\r\n\nfirst\n \r\nsecond', 2, 4096), true, 'asset counts nonblank lines and final unterminated line');
    rejects(() => validate_list_asset('first\n\x01second', 2, 4096), 'asset checks control bytes after newlines');
};

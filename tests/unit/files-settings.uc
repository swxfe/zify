import { equal, rejects, count } from '../support/assertions.uc';
import * as fs from 'fs';
import { catalog } from 'strategies';
import { settings, settings_text, default_settings } from 'settings';
import { read, tempdir } from 'common';
import { read_applied, create_applied } from 'applied';
import { inspect_strategy } from 'status';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let home = f.home, ctx = f.ctx, list = f.list, v7 = f.v7;
    equal(ctx.profile, 'zapret', 'default profile');
    let original_state = create_applied(v7, inspect_strategy(v7, list), list, 123);
    let dir = tempdir();
    assert(dir != null, 'temporary directory');
    let file = dir + '/sample';
    fs.writefile(file, '#one\n--x=1\n#one\n--x=2\n');
    rejects(() => catalog(ctx, file), 'duplicate strategy');
    fs.writefile(file, 'abc\x00def');
    rejects(() => read(file, 128), 'NUL input');
    fs.writefile(file, 'abcdef');
    rejects(() => read(file, 2), 'file size limit');
    fs.writefile(file, "config zify main\n option root '/../etc'\n");
    rejects(() => settings(home, file, null), 'path traversal');
    fs.writefile(file, "config zify main\n option unexpected '1'\n");
    rejects(() => settings(home, file, null), 'unknown setting');
    let defaults = default_settings();
    fs.writefile(file, settings_text(defaults));
    let loaded = settings(home, file);
    equal(loaded.connect_timeout, defaults.connect_timeout, 'read native UCI number');
    equal(loaded.updater, null, 'updater is not a UCI setting');
    equal(loaded.sources, null, 'package repository is not a UCI setting');
    equal(loaded.file, file, 'explicit UCI file path');
    equal(index(settings_text(defaults), 'config updater'), -1, 'generated UCI omits updater');
    equal(index(settings_text(defaults), 'config sources'), -1, 'generated UCI omits sources');
    fs.writefile(file, settings_text(defaults) + "config updater updater\n option repo 'untrusted/update'\n option branch 'other'\n option path 'other.sh'\nconfig sources sources\n option installer_repo 'untrusted/package'\n");
    equal(settings(home, file).updater, null, 'legacy updater cannot override code constants');
    equal(settings(home, file).sources, null, 'legacy sources cannot override code constants');
    fs.writefile(file, "config zify main\n option settle_seconds '0'\n");
    equal(settings(home, file).max_file_bytes, 2097152, 'partial UCI uses safe defaults');
    equal(settings(home, file).settle_seconds, null, 'retired options cannot affect runtime');
    equal(index(settings_text(settings(home, file)), 'settle_seconds'), -1, 'retired options are not emitted');
    for (let invalid in ["config zify main\n option max_domains '5oops'\n",
        "config zify main\n list max_domains '5'\n", "config zify other\n",
        "config zify main\n option request_timeout '99999999'\n",
        "config zify main\n option root '/tmp/../etc'\n", '{"root":"/"}',
        "config zify main\n option root '/\x00bad'\n"]) {
        fs.writefile(file, invalid);
        rejects(() => settings(home, file), 'invalid UCI is rejected');
    }
    let state_ctx = { state: dir };
    equal(read_applied(state_ctx), null, 'missing state file');
    fs.writefile(dir + '/state.json', sprintf('%J', original_state));
    equal(read_applied(state_ctx), original_state, 'read saved applied state');
    fs.writefile(dir + '/state.json', '{broken');
    rejects(() => read_applied(state_ctx), 'reject corrupted state JSON');
    fs.unlink(dir + '/state.json');
    // A real file called @default must never alias the embedded-catalog cache key.
    let cached_ctx = { ...ctx, cache: {} }, previous_directory = fs.getcwd();
    catalog(cached_ctx);
    fs.writefile(dir + '/@default', '#local\n--x=1\n');
    fs.chdir(dir);
    try { equal(catalog(cached_ctx, '@default')[0].name, 'local', 'file path cannot collide with builtin catalog cache'); }
    catch (e) { fs.chdir(previous_directory); fs.unlink(dir + '/@default'); die(e.message); }
    fs.chdir(previous_directory);
    fs.unlink(dir + '/@default');
    fs.unlink(file);
    fs.rmdir(dir);
};

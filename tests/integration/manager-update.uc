import * as fs from 'fs';
import { sha256 } from 'digest';
import { execute } from 'console';
import { settings } from 'settings';
import { check, read } from 'common';
import { check_update, update_status, apply_update } from 'manager';

let ctx = settings(getenv('ZIFY_HOME'), getenv('ZIFY_UPDATE_CONFIG'));
let path = ctx.root + '/usr/bin/zify';
let before = read(path, ctx.max_file_bytes);
let config = read(ctx.config, ctx.max_file_bytes);
let service = fs.readfile(ctx.root + '/service-actions');
function fixture(version, mode) {
    check(execute(['python3', ctx.home + '/tests/integration/update-fixture.py', ctx.root,
        getenv('ZIFY_UPDATE_BASE'), getenv('ZIFY_ASSETS_ARCHIVE'), version, mode]) == 0, 'prepare future release');
}
function snapshot() {
    let result = {};
    function walk(directory) {
        for (let name in fs.lsdir(directory)) {
            let file = directory + '/' + name, st = fs.lstat(file);
            if (st.type == 'directory') walk(file);
            else result[file] = sha256(fs.readfile(file));
        }
    }
    walk(ctx.assets); walk(ctx.base + '/fakes');
    return sprintf('%J', result);
}
check(!update_status(ctx).available, 'no update before metadata check');
fixture('1.1', 'valid');
let info = check_update(ctx);
check(info.available && info.version == '1.1', 'offer newer release');
apply_update(ctx);
check(read(path + '.previous', ctx.max_file_bytes) == before, 'preserve previous executable');
let installed = read(path, ctx.max_file_bytes), assets = snapshot();
check(index(installed, '# ZIFY_VERSION=1.1\n') != -1, 'install selected release');
check(json(fs.readfile(ctx.assets + '/manifest.json')).version == '1.1', 'update resource version together');
check(index(fs.readfile(ctx.base + '/fakes/stun.bin'), 'release-1.1') != -1, 'update fake bytes');
check(fs.stat(ctx.assets + '/licenses/NOTICE')?.size > 0, 'install attribution');
for (let mode in ['invalid-code', 'corrupt-assets']) {
    fixture('1.2', mode);
    check_update(ctx);
    let rejected = false;
    try { apply_update(ctx); } catch (e) { rejected = true; }
    check(rejected && read(path, ctx.max_file_bytes) == installed, 'failed update preserves executable: ' + mode);
    check(read(path + '.previous', ctx.max_file_bytes) == before, 'failed update preserves previous executable');
    check(snapshot() == assets, 'failed update restores every resource and fake: ' + mode);
    check(fs.stat(ctx.root + '/tmp/zify.zapret.lock') == null, 'failed update cleans staging');
}
check(read(ctx.config, ctx.max_file_bytes) == config, 'updates preserve active configuration');
check(fs.readfile(ctx.root + '/service-actions') == service, 'updates preserve service state');
fs.writefile(ctx.root + '/update-offline', '1');
let rejected = false;
try { check_update(ctx); } catch (e) { rejected = true; }
check(rejected && update_status(ctx).version == '1.2', 'offline check preserves last metadata');
print('update: atomic code/resources, hashes, previous copy, failure rollback and offline cache OK\n');

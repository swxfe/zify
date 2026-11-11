import * as fs from 'fs';
import { sha256 } from 'digest';

function request(url, options) {
    let root = getenv('ZIFY_TEST_ROOT');
    let reply = { status: 200, headers: {}, body: '' };
    let flag = (name) => fs.stat(root + '/' + name) != null;
    let contents = (name) => fs.readfile(root + '/' + name);
    if (substr(url, 0, 23) == 'https://api.github.com/') {
        if (flag('api-transport-fail')) die('transport timeout');
        if (flag('api-status')) reply.status = +trim(contents('api-status'));
        if (flag('api-remaining')) reply.headers['x-ratelimit-remaining'] = trim(contents('api-remaining'));
        if (flag('api-body')) { reply.body = contents('api-body'); return reply; }
    }
    if (index(url, '/swxfe/zify/') != -1) {
        let base = 'https://raw.githubusercontent.com/swxfe/zify/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/dist/';
        if (flag('update-offline')) die('offline update');
        if (url == 'https://api.github.com/repos/swxfe/zify/git/ref/heads/main') {
            reply.body = '{"ref":"refs/heads/main","object":{"type":"commit","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}';
        }
        else if (url == base + 'zify.sh') reply.body = contents('manager-release');
        else if (url == base + 'zify-assets.tar.gz') reply.body = flag('manager-assets') ? contents('manager-assets') : fs.readfile(getenv('ZIFY_ASSETS_ARCHIVE'));
        else if (url == base + 'release.json') {
            if (flag('manager-index')) reply.body = contents('manager-index');
            else {
                let code = contents('manager-release') || '', assets = fs.readfile(getenv('ZIFY_ASSETS_ARCHIVE'));
                let version = match(code, /# ZIFY_VERSION=([0-9.]+)/);
                reply.body = sprintf('%J', {format:1, bundle_format:2, version:version ? version[1] : '1.0',
                    code:{path:'dist/zify.sh', size:length(code), sha256:sha256(code)},
                    assets:{path:'dist/zify-assets.tar.gz', size:length(assets), sha256:sha256(assets)}});
            }
        }
        else die('unexpected application update endpoint');
        return reply;
    }
    if (flag('mock-release') && index(url, '/remittor/zapret-openwrt/releases/latest') != -1) {
        reply.body = '{"tag_name":"v72.20260307","assets":[]}'; return reply;
    }
    if (!length(reply.body)) reply.body = contents('download');
    return reply;
};

return { request };

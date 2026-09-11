import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

// Execute the service's actual QML method bodies. Only processes, timers and
// property bindings are replaced. Live compositor/device checks remain manual.
const source = readFileSync(new URL('../services/Brightness.qml', import.meta.url), 'utf8');
function method(source, name) {
    const match = new RegExp(`function ${name}\\(([^)]*)\\)\\s*:\\s*\\w+\\s*\\{`).exec(source);
    assert.ok(match, `Missing method ${name}`);
    const start = match.index + match[0].length;
    let end = start, depth = 1;
    while (depth && end < source.length) {
        if (source[end] === '{') depth++;
        if (source[end] === '}') depth--;
        end++;
    }
    const args = match[1].replace(/:\s*\w+/g, '');
    return `function ${name}(${args}) {${source.slice(start, end - 1)}}`;
}
function bind(object, source, names) {
    vm.createContext(object);
    for (const name of names) vm.runInContext(method(source, name), object);
    return object;
}
function setup() {
    const root = bind({
        brightness: 0.5, brightnessInitialized: false, brightnessRequested: false,
        monitors: [], GlobalConfig: { services: { brightnessIncrement: 0.1 } },
    }, source, ['applyGlobalBrightness', 'seedBrightness', 'increaseBrightness', 'decreaseBrightness']);
    function monitor(min = 0, max = 1, ddc = true) {
        const writes = [];
        const m = {
            root, minBrightness: min, maxBrightness: max, isDdc: ddc,
            isAppleDisplay: false, backend: ddc ? 'ddc:1' : 'backlight', busNum: '1',
            brightness: NaN, uiBrightness: 0, requested: false, pending: false,
            initProc: { running: false },
            timer: { running: false, restart() { this.running = true; } },
            writeProc: {
                command: [], _running: false,
                get running() { return this._running; },
                set running(value) {
                    if (value) {
                        assert.equal(this._running, false, 'Writes must not overlap');
                        writes.push([...this.command]);
                    }
                    this._running = value;
                },
            },
        };
        m.monitor = m;
        bind(m, source.slice(source.indexOf('component Monitor:')), [
            'setBrightness', 'flushBrightness', 'acceptInitialBrightness', 'updateBounds', 'initBrightness',
        ]);
        root.monitors.push(m);
        function finish() {
            m.writeProc.running = false;
            m.timer.running = false;
            m.flushBrightness();
        }
        function drain() {
            for (let n = 0; n < 10 && (m.writeProc.running || m.pending); n++) finish();
            assert.equal(m.pending, false);
        }
        return { m, writes, finish, drain, last: () => writes.at(-1)?.at(-1) };
    }
    return { root, monitor };
}

test('one slider maps endpoints and midpoint through each monitor range', () => {
    const { root, monitor } = setup();
    const laptop = monitor(0.2, 1, false), external = monitor();
    for (const [logical, internal, ddc] of [[0, '20%', 0], [0.5, '60%', 50], [1, '100%', 100]]) {
        root.applyGlobalBrightness(logical);
        laptop.drain(); external.drain();
        assert.equal(laptop.last(), internal);
        assert.equal(external.last(), ddc);
        assert.equal(laptop.m.uiBrightness, logical);
        assert.equal(external.m.uiBrightness, logical);
    }
});

test('dragging back to the in-flight value cancels an older queued value', () => {
    const { root, monitor } = setup();
    const display = monitor();
    root.applyGlobalBrightness(0.6);
    root.applyGlobalBrightness(0.8);
    root.applyGlobalBrightness(0.6);
    display.drain();
    assert.equal(display.last(), 60);
    assert.equal(display.writes.length, 1);
});

test('rapid key presses accumulate and synchronize different starting values', () => {
    const { root, monitor } = setup();
    const laptop = monitor(0.2, 1, false), external = monitor();
    laptop.m.acceptInitialBrightness(0.6);
    external.m.acceptInitialBrightness(0.2);
    root.increaseBrightness(); root.increaseBrightness(); root.increaseBrightness();
    laptop.drain(); external.drain();
    assert.ok(Math.abs(root.brightness - 0.8) < 1e-9);
    assert.equal(laptop.last(), '84%');
    assert.equal(external.last(), 80);
});

test('narrow and fixed physical ranges never prevent logical slider movement', () => {
    const { root, monitor } = setup();
    const narrow = monitor(0.2, 0.21), fixed = monitor(0.3, 0.3);
    root.applyGlobalBrightness(0);
    narrow.drain(); fixed.drain();
    for (let i = 0; i < 10; i++) root.increaseBrightness();
    narrow.drain(); fixed.drain();
    assert.ok(root.brightness > 0.99);
    assert.equal(narrow.last(), 21);
    assert.equal(fixed.last(), 30);
    assert.ok(fixed.m.uiBrightness > 0.99);
});

test('latest drag wins through a slow write and cooldown', () => {
    const { root, monitor } = setup();
    const display = monitor();
    root.applyGlobalBrightness(0.2);
    for (let i = 0; i <= 100; i++) root.applyGlobalBrightness(i / 100);
    assert.equal(display.writes.length, 1);
    display.m.writeProc.running = false;
    display.m.timer.running = true;
    root.applyGlobalBrightness(0.7);
    assert.equal(display.writes.length, 1);
    display.drain();
    assert.equal(display.last(), 70);
});

test('initial reads cannot overwrite a newer slider request', () => {
    const { root, monitor } = setup();
    const display = monitor();
    display.m.initProc.running = true;
    root.applyGlobalBrightness(0.9);
    display.m.acceptInitialBrightness(0.1);
    display.m.initProc.running = false;
    display.m.flushBrightness(); display.drain();
    assert.equal(root.brightness, 0.9);
    assert.equal(display.m.uiBrightness, 0.9);
    assert.equal(display.last(), 90);
});

test('an external monitor waits for discovery and joins the shared level', () => {
    const { root, monitor } = setup();
    const display = monitor();
    display.m.backend = '';
    root.applyGlobalBrightness(0.4);
    assert.equal(display.writes.length, 0);
    display.m.backend = 'ddc:1';
    display.m.initBrightness(); display.drain();
    assert.equal(display.last(), 40);
});

test('live range changes remap the requested logical level', () => {
    const { root, monitor } = setup();
    const display = monitor();
    root.applyGlobalBrightness(0.5); display.drain();
    display.m.minBrightness = 0.2;
    display.m.updateBounds(); display.drain();
    assert.equal(display.last(), 60);
    assert.equal(display.m.uiBrightness, 0.5);
});

test('invalid values produce no writes and finite out-of-range values clamp', () => {
    const { root, monitor } = setup();
    const display = monitor();
    for (const value of [NaN, Infinity, -Infinity]) root.applyGlobalBrightness(value);
    assert.equal(display.writes.length, 0);
    root.applyGlobalBrightness(-1); display.drain(); assert.equal(display.last(), 0);
    root.applyGlobalBrightness(2); display.drain(); assert.equal(display.last(), 100);
});

const idleSource = readFileSync(new URL('../modules/IdleMonitors.qml', import.meta.url), 'utf8');
test('wake action runs once even if unlocking disables the monitor first', () => {
    const actions = [];
    const idle = bind({
        root: { handleIdleAction(action) { actions.push(action); } },
        modelData: { idleAction: 'off', returnAction: 'on' },
        actionRan: false, isIdle: true, enabled: true,
    }, idleSource, ['updateIdle', 'returnFromIdle']);
    idle.updateIdle();
    idle.enabled = false;
    idle.returnFromIdle();
    idle.isIdle = false;
    idle.updateIdle();
    assert.deepEqual(actions, ['off', 'on']);
});
test('an inactive lock-only timer cannot run idle or return actions', () => {
    const actions = [];
    const idle = bind({
        root: { handleIdleAction(action) { actions.push(action); } },
        modelData: { idleAction: 'off', returnAction: 'on' },
        actionRan: false, isIdle: true, enabled: false,
    }, idleSource, ['updateIdle', 'returnFromIdle']);
    idle.updateIdle(); idle.returnFromIdle();
    assert.deepEqual(actions, []);
});

test('untargeted IPC uses shared level while explicit monitor IPC stays targeted', () => {
    const { root, monitor } = setup();
    const laptop = monitor(0.2, 1, false), external = monitor();
    laptop.m.modelData = { name: 'eDP-1' };
    external.m.modelData = { name: 'DP-1' };
    root.getMonitor = query => root.monitors.find(m => m.modelData.name === query);
    const ipc = bind({ root }, source.slice(source.indexOf('    IpcHandler {')), ['get', 'getFor', 'set', 'setFor']);
    ipc.set('50%'); laptop.drain(); external.drain();
    assert.equal(ipc.get(), 0.5);
    assert.equal(laptop.last(), '60%');
    assert.equal(external.last(), 50);
    ipc.setFor('eDP-1', '10%-'); laptop.drain();
    assert.equal(laptop.last(), '52%');
    assert.equal(external.last(), 50);
    assert.equal(ipc.getFor('eDP-1'), 0.4);
    ipc.set('+10%'); laptop.drain(); external.drain();
    assert.equal(laptop.last(), '68%');
    assert.equal(external.last(), 60);
    assert.equal(ipc.getFor('missing'), -1);
    assert.match(ipc.setFor('missing', '20%'), /Invalid monitor/);
});

test('DDC discovery ignores invalid panels and incomplete display records', () => {
    const parser = bind({}, source, ['parseDdcMonitors']);
    const found = parser.parseDdcMonitors(`Invalid display
   I2C bus: /dev/i2c-4
   DRM connector: card1-eDP-1

Display 1
   I2C bus: /dev/i2c-5
   DRM connector: card1-HDMI-A-1

Display 2
   I2C bus: /dev/i2c-8

Display 3
   DRM connector: card1-DP-2
`);
    assert.equal(JSON.stringify(found), JSON.stringify([{ busNum: '5', connector: 'HDMI-A-1' }]));
    assert.equal(parser.parseDdcMonitors('').length, 0);
});

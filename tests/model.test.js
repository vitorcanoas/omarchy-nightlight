'use strict'

const assert = require('node:assert/strict')
const model = require('../Model.js')

assert.equal(model.clampPercent(-10), 0)
assert.equal(model.clampPercent(40.4), 40)
assert.equal(model.clampPercent(120), 100)
assert.equal(model.clampPercent('not a number'), 0)

assert.equal(model.clampBrightness(9), model.BRIGHTNESS_MIN)
assert.equal(model.clampBrightness(40.6), 41)
assert.equal(model.clampBrightness(120), 100)
assert.equal(model.clampBrightness('not a number'), 100)

const state = model.parseState(JSON.stringify({
  outputs: [
    { name: 'DP-2', percent: 42.4, kelvin: '4270', on: true, saved: 40, brightness: 75.4 },
    { name: '', percent: 90, kelvin: 1200, on: true, saved: 90 },
    { name: 'HDMI-A-1', percent: -5, kelvin: 6500, on: false, saved: 110 }
  ]
}))

assert.deepEqual(state.names, ['DP-2', 'HDMI-A-1'])
assert.deepEqual(state.byName['DP-2'], {
  name: 'DP-2',
  percent: 42,
  kelvin: 4270,
  on: true,
  saved: 40,
  brightness: 75
})
assert.equal(state.byName['HDMI-A-1'].percent, 0)
assert.equal(state.byName['HDMI-A-1'].saved, 100)
assert.equal(state.byName['HDMI-A-1'].brightness, 100)
assert.equal(state.warning, '')

assert.equal(model.parseState(''), null)
assert.equal(model.parseState('{"outputs":{}}'), null)
assert.equal(model.parseState('{"outputs":[]}'), null)
assert.deepEqual(model.parseState('{"warning":"daemon unavailable","outputs":[]}'), {
  names: [],
  byName: {},
  warning: 'daemon unavailable'
})

assert.equal(model.parseTime('07:05'), 425)
assert.equal(model.parseTime('7:05'), 425)
assert.equal(model.parseTime('24:00'), -1)
assert.equal(model.parseTime('07:5'), -1)
assert.equal(model.formatTime(425), '07:05')
assert.equal(model.formatTime(24 * 60), '23:59')

const at = (hour, minute) => new Date(2026, 0, 1, hour, minute)
assert.equal(model.phaseAt(at(22, 0), '20:00', '07:00'), 'night')
assert.equal(model.phaseAt(at(6, 59), '20:00', '07:00'), 'night')
assert.equal(model.phaseAt(at(7, 0), '20:00', '07:00'), 'day')
assert.equal(model.phaseAt(at(12, 0), '07:00', '20:00'), 'night')
assert.equal(model.phaseAt(at(20, 0), '07:00', '20:00'), 'day')
assert.equal(model.phaseAt(at(12, 0), 'same', 'same'), '')

assert.equal(model.summary(false, 2, 0), 'Reading state')
assert.equal(model.summary(true, 0, 0), 'No screens')
assert.equal(model.summary(true, 1, 1), 'On')
assert.equal(model.summary(true, 3, 2), '2 of 3 screens')
assert.equal(model.clampMessage('first line\nsecond line', 160), 'first line')

console.log('Model.js tests passed')

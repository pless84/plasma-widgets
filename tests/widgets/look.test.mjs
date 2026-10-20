// The shared look (code/look.js, ui/SharedLook.qml): one appearance that every widget can follow.
import { test } from "node:test"
import assert from "node:assert/strict"
import { widgets, source, loadLogic } from "./logic.mjs"

function loadLook(widget) {
    const code = source(widget, "code/look.js").replace(/^\.pragma library$/m, "")
    const names = [...code.matchAll(/^(?:function|var)\s+(\w+)/gm)].map(m => m[1])
    return new Function(`${code}\nreturn { ${names.join(", ")} }`)()
}

const Look = loadLook("githubstatus")
const docker = loadLogic("dockerstatus").colorRoles

const dockerConfig = {
    badgeStyle: "rounded", badgeSpacing: 6, logoSpacing: 2, showLogo: true,
    colorFailed: "#111111", colorUnhealthy: "#222222", colorRestarting: "#333333", colorPaused: "#444444",
    colorStopped: "#555555", colorRunning: "#666666", colorCountBackground: "#777777"
}

test("look.js and SharedLook.qml are identical in every widget", () => {
    for (const file of ["code/look.js", "ui/SharedLook.qml"]) {
        const reference = source("githubstatus", file)
        for (const widget of widgets) {
            assert.equal(source(widget, file), reference, `${widget}/contents/${file} differs from githubstatus's`)
        }
    }
})

test("parse fills in missing or invalid values from the defaults", () => {
    const look = Look.parse(JSON.stringify({ badgeStyle: "dot", badgeSpacing: 99, logoSpacing: 3, showLogo: "yes", colors: { error: "#ABCDEF", ok: "green" } }))
    assert.equal(look.badgeStyle, "square")
    assert.equal(look.badgeSpacing, 4)
    assert.equal(look.logoSpacing, 3)
    assert.equal(look.showLogo, false)
    assert.equal(look.colors.error, "#abcdef")
    assert.equal(look.colors.ok, Look.defaults.colors.ok)
    assert.deepEqual(Object.keys(look.colors), Look.roles)
})

test("parse returns null for a missing or broken file", () => {
    assert.equal(Look.parse(""), null)
    assert.equal(Look.parse("{oops"), null)
    assert.equal(Look.parse("[1, 2]"), null)
    assert.equal(Look.parse("null"), null)
})

test("parse reads back what serialize writes", () => {
    const look = Look.fromConfig(dockerConfig, docker)
    assert.deepEqual(Look.parse(Look.serialize(look)), look)
})

test("resolve uses the widget's own settings without a shared look", () => {
    const look = Look.resolve(dockerConfig, null, docker)
    assert.equal(look.badgeStyle, "rounded")
    assert.equal(look.badgeSpacing, 6)
    assert.equal(look.colors.colorFailed, "#111111")
    assert.equal(look.colors.colorCountBackground, "#777777")
})

test("resolve maps each colour setting to its shared role", () => {
    const shared = Look.parse(JSON.stringify({ badgeStyle: "square", badgeSpacing: 8, colors: { error: "#ff0000", ok: "#00ff00", countBackground: "#000000" } }))
    const look = Look.resolve(dockerConfig, shared, docker)
    assert.equal(look.badgeStyle, "square")
    assert.equal(look.badgeSpacing, 8)
    assert.equal(look.colors.colorFailed, "#ff0000")
    assert.equal(look.colors.colorRunning, "#00ff00")
    assert.equal(look.colors.colorCountBackground, "#000000")
    assert.equal(look.colors.colorPaused, Look.defaults.colors.info)
})

test("fromConfig keeps a widget's look when it becomes the shared look", () => {
    const shared = Look.fromConfig(dockerConfig, docker)
    assert.deepEqual(Look.resolve({}, shared, docker).colors, Look.resolve(dockerConfig, null, docker).colors)
    // Docker has no colour for the warning role, so it gets the default.
    assert.equal(shared.colors.warning, Look.defaults.colors.warning)
})

test("fromConfig drops the dot style, which only some widgets have", () => {
    assert.equal(Look.fromConfig({ ...dockerConfig, badgeStyle: "dot" }, docker).badgeStyle, "square")
})

test("withValue changes a copy, for settings and colour roles", () => {
    const look = Look.fromConfig(dockerConfig, docker)
    const changed = Look.withValue(Look.withValue(look, "badgeSpacing", 12), "error", "#abcdef")
    assert.equal(changed.badgeSpacing, 12)
    assert.equal(changed.colors.error, "#abcdef")
    assert.equal(look.badgeSpacing, 6)
    assert.equal(look.colors.error, "#111111")
})

test("writeCommand writes the JSON through a temporary file", () => {
    const cmd = Look.writeCommand("/home/me/.config/madebypless-widgets", "/home/me/.config/madebypless-widgets/look.json", Look.defaults)
    assert.match(cmd, /^mkdir -p '\/home\/me\/\.config\/madebypless-widgets' && printf '%s' '\{/)
    assert.match(cmd, /> '\/home\/me\/\.config\/madebypless-widgets\/look\.json\.tmp' && mv -f /)
    assert.equal(Look.shellQuote("it's"), "'it'\\''s'")
})

for (const widget of widgets) {
    test(`${widget}: every colour setting follows a shared role`, () => {
        const roles = loadLogic(widget).colorRoles
        const xml = source(widget, "config/main.xml")
        const appearance = xml.slice(xml.indexOf('<group name="Appearance">'))
        const colorKeys = [...appearance.matchAll(/<entry name="(color\w+)" type="Color">/g)].map(m => m[1])
        assert.deepEqual(Object.keys(roles).sort(), colorKeys.sort())
        for (const key of colorKeys) {
            assert.ok(Look.roles.includes(roles[key]), `${key} maps to unknown role ${roles[key]}`)
        }
        assert.equal(roles.colorCountBackground, "countBackground")
    })

    test(`${widget}: the panel reads its appearance through the shared look`, () => {
        const qml = source(widget, "ui/main.qml")
        assert.match(qml, /^import "\.\.\/code\/look\.js" as Look$/m)
        assert.match(qml, /SharedLook \{\n\s*id: sharedLook/)
        assert.match(qml, /Look\.resolve\(Plasmoid\.configuration,/)
        assert.doesNotMatch(qml, /Plasmoid\.configuration\.(color\w+|badgeStyle|badgeSpacing|logoSpacing|showLogo)\b/)
        assert.match(source(widget, "config/main.xml"), /<entry name="useSharedLook" type="Bool">\s*<label>[^<]*<\/label>\s*<default>true<\/default>/)
    })

    test(`${widget}: the Appearance page can edit the shared look`, () => {
        const qml = source(widget, "ui/configAppearance.qml")
        assert.match(qml, /property bool cfg_useSharedLook/)
        assert.match(qml, /function saveConfig\(\)/)
        assert.match(qml, /signal configurationChanged\(\)/)
        assert.doesNotMatch(qml, /page\.cfg_(badgeStyle|badgeSpacing|logoSpacing|showLogo)\b/,
                            "appearance controls should go through lookValue/setLookValue")
    })
}

// Every widget's main.qml only calls Logic.* functions that its logic.js defines. A typo there
// would only show up at runtime, often swallowed by the try/catch around apply().
import { test } from "node:test"
import assert from "node:assert/strict"
import { widgets, source, loadLogic } from "./logic.mjs"

for (const widget of widgets) {
    test(`${widget}: main.qml imports logic.js and uses only what it defines`, () => {
        const qml = source(widget, "ui/main.qml")
        assert.match(qml, /^import "\.\.\/code\/logic\.js" as Logic$/m)
        const logic = loadLogic(widget)
        const used = new Set([...qml.matchAll(/\bLogic\.(\w+)/g)].map(m => m[1]))
        assert.ok(used.size > 0)
        for (const name of used) {
            assert.ok(name in logic, `main.qml uses Logic.${name}, which logic.js doesn't define`)
        }
    })

    test(`${widget}: logic.js stays free of QML and Plasma`, () => {
        const code = source(widget, "code/logic.js")
        assert.match(code, /^\.pragma library$/m)
        const withoutComments = code.replace(/\/\/.*$/gm, "")
        assert.doesNotMatch(withoutComments, /\b(i18n|i18np|Plasmoid|Kirigami|Qt\.)\b/)
    })
}

// Popups with grouped lists let you collapse each group (GroupHeader), saved in collapsedGroups.
for (const widget of widgets) {
    test(`${widget}: popup groups are collapsible`, () => {
        const qml = source(widget, "ui/main.qml")
        assert.match(qml, /component GroupHeader: Kirigami\.ListSectionHeader/)
        assert.doesNotMatch(qml.replace(/component GroupHeader: Kirigami\.ListSectionHeader/, ""), /Kirigami\.ListSectionHeader/,
                            "every section header should be a GroupHeader")
        assert.match(source(widget, "config/main.xml"), /<entry name="collapsedGroups" type="StringList">/)
        const L = loadLogic(widget)
        assert.deepEqual(L.toggled(["a"], "b"), ["a", "b"])
        assert.deepEqual(L.toggled(["a", "b"], "a"), ["b"])
    })
}

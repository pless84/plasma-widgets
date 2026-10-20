// Loads a widget's contents/code/logic.js the way QML does (a ".pragma library" script whose
// top-level functions and vars are its API) and returns that API.
import { readFileSync } from "node:fs"

export const widgets = ["githubstatus", "githubaccount", "prtgstatus", "dockerstatus", "bugsinkstatus", "dokploystatus", "runnerstatus", "sentrystatus", "llmstatus"]

export function source(widget, file) {
    return readFileSync(new URL(`../../${widget}/contents/${file}`, import.meta.url), "utf8")
}

export function loadLogic(widget) {
    const code = source(widget, "code/logic.js").replace(/^\.pragma library$/m, "")
    const names = [...code.matchAll(/^(?:function|var)\s+(\w+)/gm)].map(m => m[1])
    return new Function(`${code}\nreturn { ${names.join(", ")} }`)()
}

// A time `minutes` before `now`, as the APIs send it.
export function isoAgo(now, minutes) {
    return new Date(now - minutes * 60000).toISOString()
}

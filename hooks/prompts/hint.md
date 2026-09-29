Most files in this project end with a generated `@sourcemap` comment block: `@ctx:` says what the file does, `@dependents:` lists the files that import it.
To find the files relevant to a task, first grep case-insensitively for `@ctx:.*(word1|word2)` with words describing what the code does (e.g. `@ctx:.*(aircraft|waypoint)`): it returns one description line per file, instead of every line of code that mentions the words. Open only the files whose description fits; grep the code itself only if that finds nothing.
Before changing a file's exports or behavior, check its `@dependents:`.
The blocks are maintained automatically and never reach git: never edit, move, or copy one, and never add one to a new file.

# AGENTS.md

## Project

`gitlab-modes` is an Emacs package for GitLab merge requests and CI
pipelines.  One buffer shows one merge request or one pipeline.  A
separate mode shows a collection as a table.  Every display buffer
refreshes itself through `auto-revert-mode` and never blocks Emacs.

The package reads GitLab through the `glab` command line program.  The
Nix build substitutes `gitlab-program` with the store path of the
nixpkgs `glab` package.  The package has no native HTTP transport yet.
The git-bug issue `cabdead` holds the design for that backend.

The license is AGPL-3.0-or-later.  Read `LICENSE`.

## Files

| File | Purpose |
|---|---|
| `gitlab-modes.el` | Entry library and package namesake.  Requires the data layer, the display layer, the ID prompts, both resource families and the JSON export.  `(use-package gitlab-modes ...)` and `:ensure t` load and resolve through it.  An autoloaded form loads the evil layer at the load of evil and enables it. |
| `gitlab-error.el` | Package-wide parent condition `gitlab-error` and the `gitlab` customization group.  `gitlab-cli-error` and `gitlab-cli-timeout` cover the CLI transport.  `gitlab-api-error` and `gitlab-api-timeout` reserve the native transport.  `gitlab-backend-error` reports an unsupported backend. |
| `gitlab-cli.el` | glab transport: `gitlab-program`, `gitlab-repository`, `gitlab-cli-directory`, `gitlab-cli-timeout`, `gitlab-cli-request` (sync), `gitlab-cli-request-async`, `gitlab-cli-stream`, `gitlab-cli-project-endpoint`, `gitlab-cli-response-text`, the project.el directory helper, argument helpers.  A stream takes an optional chunk filter.  JSON decodes to an alist with symbol keys.  JSON false decodes to `:false`; JSON null decodes to nil. |
| `gitlab-data.el` | Data layer: `gitlab-backend`, field accessors, the identifier syntax (`gitlab-data-identifier`, `gitlab-data-identifier-split`, `gitlab-data-identifier-signs`), the list cache, and the merge request, pipeline and job entry points.  No buffer, mode, face or key code.  `gitlab-backend` accepts `cli`; `api` signals `gitlab-backend-error`. |
| `gitlab-mode.el` | Display layer: customization, faces, the detail base mode, the list base mode, the asynchronous refresh pipeline, the stale check, the field and value renderers, imenu, the navigation commands, the bookmark records and `gitlab-bookmark-jump`. |
| `gitlab-read.el` | ID completion: `gitlab-read-merge-request-iid`, `gitlab-read-pipeline-id`, `gitlab-read-job-id`.  The prompts read the cached lists and accept a typed ID. |
| `gitlab-merge-request.el` | Merge request list mode, detail mode, display commands and the notes command. |
| `gitlab-pipeline.el` | Pipeline list mode, pipeline detail mode with the jobs table, and the streaming job log mode. |
| `gitlab-export.el` | `gitlab-export-json`, the single JSON export buffer, the fallback encoder and the `js-json-mode` remaps of both display base modes. |
| `gitlab-evil.el` | Optional evil layer: the global `gitlab-evil-mode`, the auto enable function, the option `gitlab-evil-auto-enable` and three local minor modes.  The package does not depend on evil. |
| `ol-gitlab.el` | Optional Org link types: `gitlab-mr:`, `gitlab-pipeline:` and `gitlab-job:`.  Follow, store and export.  A path names its project with the bookmark identifier. |
| `gitlab-xref.el` | Optional xref backend: `mr:`, `pipeline:` and `job:` identifiers, with an optional project path.  Text properties win over a typed identifier. |
| `test/gitlab-test-helpers.el` | Shared ERT helpers: the mock program path, the environment macro and the process wait helper. |
| `test/mock-glab` | Offline glab stand-in.  It reads `test/fixtures` and never opens a network connection. |
| `test/fixtures/` | Minimal glab JSON, a job trace and a pipeline without a jobs array. |
| `*-tests.el` | ERT suites.  `package-build` excludes this suffix from the package and the lint gate skips it. |
| `flake.nix` | flake-parts flake with one `melpaBuild` for the whole repo, the glab store path patch, the evil load path for the install compile, the ERT check phase and the package-lint, checkdoc and treefmt checks.  The package goes through `lib.makeOverridable`, so `packages.default.override` swaps the Emacs package set, `melpaBuild`, the version, the glab store path or the evil package. |
| `flake.lock` | Pinned flake inputs. |
| `README.org` | User documentation. |
| `AGENTS.md` | This file. |
| `LICENSE` | AGPL-3.0. |

## Build and test

```sh
nix build          # package; its check phase byte-compiles and runs ERT
nix flake check    # package, package-lint, checkdoc, treefmt
nix fmt            # nixfmt via treefmt
nix develop        # emacs with evil, and glab
```

Without Nix:

```sh
emacs --batch -L . -L test -L "$EVIL" -l gitlab-test-helpers.el \
  -l gitlab-cli-tests.el -l gitlab-data-tests.el \
  -l gitlab-mode-tests.el -l gitlab-merge-request-tests.el \
  -l gitlab-pipeline-tests.el -l gitlab-export-tests.el \
  -l gitlab-read-tests.el -l gitlab-evil-tests.el -l ol-gitlab-tests.el \
  -l gitlab-xref-tests.el -l gitlab-bookmark-tests.el \
  -f ert-run-tests-batch-and-exit
```

`EVIL` is the directory that holds `evil.el`.  All other tests run
without evil.  The suite never opens a network connection.

## Conventions

- Dependencies point down only: transport (`gitlab-cli.el`), data
  (`gitlab-data.el`), presentation.  `gitlab-data.el` never opens a
  buffer, reads no buffer-local variable and loads no mode library.  A
  consumer that requires `gitlab-data` gets the data entry points.
- All reads go through the type-keyed data entry points.  A mode never
  builds a glab command by hand and never calls `gitlab-program`
  directly.  This keeps the planned `api` backend a transport swap.
- The data layer has a synchronous and an asynchronous form for every
  read.  The synchronous form serves prompts and tests.  The display
  buffers use the asynchronous form.  A fetcher returns its process
  object so `gitlab--kill-pending` can cancel it.
- JSON is an alist with symbol keys.  Read a field with
  `gitlab-data-field`; it compares strings and symbols.  Do not
  normalize the raw shape.  `:false` is JSON false and nil is JSON null.
  Use `gitlab-data-set-field` to merge a missing field, because the
  built-in `alist-get` setter does not mutate a non-empty list for a
  missing key.
- The data cache serves prompts only.  `gitlab-cache-ttl` controls it;
  `gitlab-cache-clear` and `gitlab-cache-invalidate` drop entries.  A
  display buffer fetches fresh data on every refresh.
- `gitlab-pipeline-show` and its asynchronous form read the jobs array
  from `glab ci get --output json`.  When the array is missing, the
  data layer fetches `projects/:id/pipelines/:pipeline_id/jobs` once and
  merges the answer.  The renderer always sees a `jobs` key.  The
  asynchronous form stores the follow-up process in the
  `gitlab-cli-follow-up` property of the first process, so a cancel
  stops both.
- The notes and jobs endpoints ask for `?per_page=100` and do not pass
  `--paginate`.  `--paginate` concatenates one JSON array per page, and
  one `json-parse-string` call cannot read that.  A collection with
  more than 100 items shows the first page only.
- `gitlab-cli-request` takes `PARSE` as `json` (the default) or `text`.
  A nil value means `json`.  The job trace uses `text`.
- The CLI process environment adds `GLAB_NO_PROMPT=1`.  A prompt would
  wait forever in batch Emacs.  Do not remove it.
- A synchronous `make-process` needs `:sentinel #'ignore`.  The default
  sentinel writes "Process ... finished" into the output buffer and
  corrupts JSON.  The asynchronous forms supply their own sentinel.
- `gitlab-cli--repository-arguments` appends `--repo` when
  `gitlab-repository` is set and the caller did not name one as
  `--repo`, `--repo=X`, `-R` or `-RX`.  The API endpoint helper
  URL-encodes a namespace path, or uses the `:id` placeholder for glab
  inference.
- `gitlab-cli-directory` selects the directory in which glab runs.  A
  nil value means `default-directory`, so a prompt runs in the project
  of the user.  Every process creation binds `default-directory` to
  `gitlab-cli-directory-of'.  `gitlab-cli--project-directory` asks
  project.el for the root of a directory and returns the directory
  itself when it belongs to no project.
- A stream has no timeout by default.  `gitlab-cli-stream` takes a
  TIMEOUT only when a caller wants one, because a job trace can run for
  hours.  The synchronous and asynchronous requests keep
  `gitlab-cli-timeout`.  The last optional argument is a chunk filter:
  it receives the process and one chunk and writes the chunk itself, so
  the job log can assemble lines before it inserts them.
  `gitlab-cli--insert-chunk` inserts text, applies ANSI colors and
  clears the modified flag, and it returns the start position of the
  text.
- Errors signal a condition that derives from `gitlab-error`.  A public
  function documents the conditions it raises.  An asynchronous error
  callback receives a condition list, not a string.
- `gitlab--refresh` and `gitlab-list--refresh` share one pipeline.  An
  in-flight fetch sets `gitlab--pending`; a refresh during that fetch
  sets `gitlab--refresh-requested` and runs when the fetch completes.
  An unchanged answer (`equal`) is not rendered again.
- Both display modes wire `revert-buffer-function` to
  `gitlab--revert-buffer` and `buffer-stale-function` to
  `gitlab--buffer-stale-p`.  The revert function fetches the collection
  in a list buffer and the object in a detail buffer.  The stale
  check returns nil while a fetch runs and, with
  `gitlab-refresh-visible-only`, in a buffer that no window shows.
  `gitlab-refresh-fast-interval` applies while a status in
  `gitlab-transitional-states` shows.
- With `gitlab-refresh-finished-pipelines` (default t), the stale
  check also returns nil in a settled pipeline buffer.
  `gitlab--settled-p` reports a `pipeline` kind whose status is not in
  `gitlab-transitional-states` and whose `jobs` array holds no such
  status either.  A final pipeline cannot change without a user
  action.  A list buffer, a merge request buffer and a pipeline with a
  nil status keep polling, because a new object or a reopened
  collection can arrive.  A manual `revert-buffer` still fetches, so a
  restarted job shows again; the settle check then applies to the new
  answer.
- Display buffers are views.  `default-directory` is the project root
  of the buffer that opened the display, `buffer-modified-p` stays
  nil, and `kill-buffer` asks no question.  A new display path must
  call `gitlab--use-project-directory`,
  `gitlab--update-list-buffers-directory` and
  `(set-buffer-modified-p nil)`.
- `gitlab--update-list-buffers-directory` sets the buffer-local
  `list-buffers-directory` to `gitlab-data-identifier` of the project
  and the object ID, so `list-buffers` shows `group/project!12` for a
  merge request, `#` for a pipeline and `&` for a job log.  A list
  buffer has no object ID and gets the project path alone.
- A display buffer keeps the project root of the buffer that opened it
  in `gitlab-cli-directory`, because glab must run in the project.
  `gitlab--use-project-directory` sets both variables from the
  project.el answer.  Call it in `gitlab--prepare-detail`,
  `gitlab-list--show` and `gitlab-pipeline--prepare-job-log`, so a
  second display of the same buffer never captures an old project.
  The same helper captures `gitlab-repository` buffer-locally: a
  bookmark jump and an xref definition bind another project around the
  display command, and a later auto refresh must read that project
  again.  It kills the previous buffer-local value first, so the
  capture reads the binding of the caller and not the value of an
  earlier display in the same buffer.
- `gitlab--prepare-detail` and `gitlab-pipeline--prepare-job-log`
  return a buffer without displaying it.  The xref backend uses them, so
  a definition never moves the window configuration.
- The renderers attach text properties.  `gitlab-field` names a field
  line.  `gitlab-pipeline-id`, `gitlab-merge-request-iid`,
  `gitlab-job-id` and `gitlab-url` are navigation targets.
  `gitlab-open-at-point` reads them.  A new object type adds one property
  and one branch there.
- The merge request detail renders every top-level JSON field.  Nested
  objects go through `gitlab--format-object`: a user becomes
  `Name (@username)`, a milestone its title, and an object with `id`
  and `status` becomes `#ID status`.  Only an object that also has
  `ref` or `sha` carries `gitlab-pipeline-id`; any other keeps the
  plain text or a `gitlab-url` link.  Empty strings and nil render as
  `-`.
- The pipeline detail uses a hand-written jobs table, not
  `tabulated-list-mode`, because the pipeline fields occupy the same
  buffer.  Every job row carries `gitlab-job-id` and `gitlab-job-name`.
  `gitlab-pipeline--render` restores point to the same job row or to
  the same field line.
- The job log streams `glab ci trace`.  `gitlab-cli-stream` inserts
  chunks into a read-only buffer, applies ANSI colors and clears the
  modified flag.  Killing the buffer deletes the process.  The buffer
  has no stale check.  `gitlab-job-log--start` erases the buffer first,
  so a second display of the same job never appends a second trace.
  `gitlab-job-log-restart` serves as `revert-buffer-function`, so it
  accepts and ignores the two `revert-buffer` arguments.
- The job log installs a chunk filter, because a process filter
  receives arbitrary chunks.  `gitlab-job-log--write` joins the tail of
  the previous chunk (`gitlab-job-log--pending`), so a line that a
  chunk cut in two reaches the buffer as one line.  Both callbacks of
  the stream flush the pending tail.  The filter drops the banner that
  `glab ci trace` prints on every run ("Getting job trace..." and
  "Showing logs for NAME job #ID."), and the empty lines before the
  first trace line, so the header line is the only place that names the
  job.
- GitLab prefixes a trace line with an ISO 8601 timestamp and a stream
  identifier (00O, 01O, 01E) when the job enables runner timestamps.
  `gitlab-job-log--apply-timestamps` marks the timestamp with the text
  property `gitlab-job-log-timestamp` and hides it with a `display`
  property when `gitlab-job-log-show-timestamps` is nil.  The text
  stays in the buffer, so `gitlab-job-log-toggle-timestamps`, bound to
  `~` and to the evil remap of `evil-invert-char`, never fetches again.
  The prefix is marked after the ANSI conversion, because a trace line
  starts with the escape sequences of the server.
- List modes derive from `gitlab-list-mode`, which derives from
  `tabulated-list-mode`.  A derived mode sets
  `gitlab-list--fetch-function`, `gitlab-list--entries-function`,
  `gitlab-list--rows-function` and `gitlab-list--open-function`, and
  sets `gitlab-list--kind`.  The row ID is the merge request IID or the
  pipeline ID, so an update keeps point on the same row.
  `gitlab-change-functions` receives `gitlab-list--kind` and a nil ID
  for a list buffer, because one collection has no single ID.
- `gitlab-list-mode` appends a `url` provider to
  `thing-at-point-provider-alist`.  `gitlab-list--thing-at-point-url`
  returns the `web_url` field of `gitlab-list--row-at-point`, so
  `thing-at-point 'url` and `browse-url-at-point` answer with the
  upstream URL of the object on the current line.  The provider
  returns nil on a line without a row, and `thing-at-point` then falls
  back to its own scan.  `gitlab-list-open-web` and the provider share
  that function, so `w` and `thing-at-point` never disagree.
- The list columns live in `gitlab-merge-request-list-format` and
  `gitlab-pipeline-list-format`.  Numeric columns use
  `gitlab-list--number-sort`.  A `tabulated-list` SORT predicate
  receives whole `tabulated-list-entries` elements, not the cell
  strings, so the helper reads the sorted column from the entry and
  strips the `!` of a merge request IID.  A date column goes through
  `gitlab-list--date-cell`, so the cell carries `gitlab-date`.
- A list buffer shows a header line from `gitlab-list--header-line`:
  the collection name, the row count, the sort column and the refresh
  state.  `gitlab-list-mode` stores the format in
  `gitlab--header-line-format`.  `gitlab--set-error` replaces the
  header line of a detail buffer, and `gitlab--clear-error` restores
  `gitlab--header-line-format`, so a list header line survives an
  error.  A list error still goes to `mode-line-process`.
- `gitlab-export-json` exports the answer of the current display
  buffer.  The transport binds `gitlab-cli-response-text` around an
  asynchronous SUCCESS callback, and the refresh pipeline stores that
  raw text in the buffer-local `gitlab--raw-text`.  The export uses the
  raw text, so it matches `glab ... --output json` byte for byte.  A
  fetch that merges two answers sets `gitlab--raw-text` to nil, and the
  export encodes `gitlab--last-data` with `json-false` bound to
  `:false`.  One buffer, named by `gitlab-export-json-buffer-name`,
  serves every export.  It stays read-only, unmodified and a snapshot.
  Both display base modes remap `js-json-mode` to the command, and the
  job log mode does not, because a trace has no JSON answer.  The
  export layer lives in `gitlab-export.el` and loads from
  `gitlab-modes.el`.
- Every face inherits a standard face and lives in `gitlab-mode.el`.
  Status faces come from `gitlab-status-faces`; do not apply a
  font-lock face in a renderer.
- Colors, dates, identifiers and status values go through
  `gitlab--field-value-face`, `gitlab--format-date` and
  `gitlab-status-face`.  A new date field goes into
  `gitlab-date-fields`; a new identifier field goes into
  `gitlab-id-fields`, so `id`, `iid`, `project_id`, `sha` and
  `before_sha` share `gitlab-id`.
- Interactive entry points carry `;;;###autoload` cookies.  The
  optional layers keep their own files and are not required by
  `gitlab-modes.el`.
- `gitlab-evil.el` binds every command key through
  `evil-define-minor-mode-key`, one key set per state and local minor
  mode.  A key that evil already binds becomes a `[remap
  EVIL-COMMAND]` vector, so the binding follows the command and not
  the key, and a user who moves `evil-ret` elsewhere keeps the
  behaviour.  A key without an evil command, such as `gr`, stays a
  key string.  `gitlab-evil--key-sequence` passes a vector unchanged
  and parses a string.  `gitlab-job-log-toggle-timestamps` takes the
  `evil-invert-char` remap, so `~` toggles the timestamps of a job log
  in normal state.  `gitlab-export-json` takes the `evil-yank`
  remap, so `y` exports the JSON of a detail buffer or of a list
  buffer in normal state, and visual state keeps the ID copy.  Do not
  `require` evil at the top of the file:
  evil runs `evil-after-load-hook` before it provides its feature, so
  a plain `require` recurses there.  The file requires evil only when
  `evil-define-minor-mode-key` is absent, and it declares that
  function for the byte compiler.  Do not add evil to
  `Package-Requires` or `packageRequires`; the check phase and the
  `preInstall` compile put evil on the load path instead.
- `gitlab-modes.el` carries one autoloaded `add-hook` form for
  `evil-after-load-hook` and one plain `(when (featurep 'evil) ...)`
  form.  Together they load `gitlab-evil` and call the autoloaded
  `gitlab-evil-auto-setup`, which enables `gitlab-evil-mode` unless
  the option `gitlab-evil-auto-enable` is nil.  The hook covers a load
  of evil after this library, the plain form covers the other order.
  A user without evil loads nothing extra.  Do not use
  `with-eval-after-load` or `after-load-functions` here: package-lint
  warns about the first, and the second fired during a byte-compile
  scan and caused a recursive load.
- `ol-gitlab.el` registers the link types at load.  A `:store`
  function calls `org-link-store-props` and returns nil outside a
  GitLab buffer, because Org calls every store function in every
  buffer and a signal there breaks `org-store-link` for all link types.
  The export function writes a web URL when `gitlab-repository' is
  set, because the URL needs the project path: an HTML anchor, a
  markdown link, a LaTeX `\href`, and the text with the URL after it
  for every other backend.
- `gitlab-xref.el` registers its backend through an autoloaded
  `add-hook` form.  It accepts text properties first, then a typed
  `mr:`, `pipeline:` or `job:` identifier.  A merge request list cell
  shows `!IID`, so the backend strips the sigil before it names a
  buffer or a glab argument.
- One identifier syntax names one object.  `gitlab-data-identifier`
  builds `REPOSITORY<SIGIL>ID` and `gitlab-data-identifier-split`
  parses it back; the sigils come from `gitlab-data-identifier-signs`
  (`!` merge request, `#` pipeline, `&` job).  A GitLab project path
  holds letters, digits, dots, hyphens and underscores only, so a
  sigil never appears in a path.  A text without the sigil is a bare
  ID, so an older Org link or bookmark keeps its meaning, and
  `gitlab-web-url` takes the repository as an optional third argument.
  Bookmarks, Org links and xref use this syntax in all three places;
  do not add a second spelling.  `string-trim` takes a regexp, so trim
  both ends with `"/+"` twice, not with one `"/"`.
- Bookmarks live in the display layer, so every user has them without
  a load step.  `gitlab--init-display-buffer` sets
  `bookmark-make-record-function` to `gitlab--bookmark-make-record`,
  and `gitlab-job-log-mode` sets its own wrapper because it does not
  run the display base mode; the wrapper adds the job name.
  `gitlab--bookmark-make-record` stores `kind`, `id`, `location`,
  `repository`, `directory` and `target`, plus `arguments` and `sort`
  for a list buffer.  The kind of a list buffer is the collection kind
  with a `-list` suffix, and `gitlab--bookmark-base-kind` gives the
  object kind back.  A new bookmarkable kind needs one entry in
  `gitlab--bookmark-labels`, one in `gitlab--bookmark-link-types` and
  one `pcase` branch in `gitlab-bookmark-jump`.
- A target names a field line, a job row or a list row, never a buffer
  position, because the first render erases the buffer and moves point
  to its start.  `gitlab--goto-property` and `gitlab-list--goto-id`
  find the target again, and both fall back to `point-min` when the
  object is gone.  `gitlab--target` belongs to the display buffer, so a
  jump binds the dynamic `gitlab--pending-target` and
  `gitlab--init-display-buffer` copies it; the handler must not
  `setq-local` in the caller.  `gitlab--apply-target` runs at the end
  of `gitlab--render` and clears the target, so a later auto refresh
  keeps point through the text property instead of jumping back.
  `gitlab-bookmark-jump` restores the project and the directory by
  binding `gitlab-repository` and `gitlab-cli-directory`, then
  dispatches on the kind and sets `bookmark-handler-type` for the type
  column of `bookmark-bmenu`.
- Tests run offline.  Mock at the process level with `test/mock-glab`;
  never call a real GitLab.  A new command needs an ERT test and, when
  it adds a file, a line in `checkPhase` only if the glob misses it.
  The export tests compare the export buffer with the fixture text, so
  a raw answer must survive the fetch unchanged.
- Byte-compilation runs with warnings as errors.  Declare a function
  from another file with `declare-function` when the file does not
  require it.  The test helper marks its dynamically bound variables
  special at compile time.
- `checkdoc` and `package-lint` must pass through `checks.checkdoc` and
  `checks.package-lint`.  The package-lint check whitelists `gitlab`
  and `ol-gitlab` as shared prefixes.
- `nix fmt` formats `flake.nix`.  Do not run nixfmt standalone.
- `gitlabModes` in `flake.nix` calls `lib.makeOverridable` with one
  argument set: `emacs`, `emacsPackages`, `melpaBuild`, `version`,
  `glab` and `evil`.  The flake passes the commit-derived `version`, and
  the argument defaults to `"0.1.0"` for a plain import.  Every other
  dependency derives from `emacs`, so one override moves them all.  A
  new build input becomes a new named argument, not a hard-coded
  binding.

## TODO

- Native `api` backend.  The design is in git-bug issue `cabdead`:
  `url.el` transport, token discovery, pagination, cancellation and a
  parity test against the CLI fixtures.
- More filters for the list commands: state, scope, labels and author.
- Merge request discussions by discussion, not one flat notes list.
- Pipeline actions: retry, cancel and play a manual job.
- A second detail buffer for a job with its metadata, not only the log.

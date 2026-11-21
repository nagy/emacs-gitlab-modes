# AGENTS.md — emacs-gitlab-modes

## Purpose

`gitlab-modes` gives Emacs a GitLab client for merge requests, work
items and CI pipelines.  One buffer shows one object or one
collection.  A display buffer refreshes through `auto-revert-mode`
and never blocks Emacs.

The package reads GitLab with the `glab` command line program.  Emacs
30.1 or later.  License: AGPL-3.0-or-later.

Read `README.org` for the commands, the keys, the options and the
faces.  Each source file carries a `;;; Commentary` block that states
the design of its own layer.

## Layout

- `gitlab-modes.el`: entry library.  Requires every other layer, so
  `(use-package gitlab-modes)` reaches the whole package.
- `gitlab-error.el`: condition tree and the `gitlab` customization
  group.
- `gitlab-cli.el`: glab transport, arguments, project spelling, JSON
  decode, stream.
- `gitlab-data.el`: data entry points per resource, list cache, write
  entry points.
- `gitlab-git.el`: local Git reads, the project context and the Magit
  views.
- `gitlab-mode.el`: display layer, both base modes, the refresh
  pipeline, point keeping, faces, buttons, text links, imenu,
  navigation and bookmarks.
- `gitlab-merge-request.el`, `gitlab-work-item.el`, `gitlab-pipeline.el`:
  resource families.  Each one carries a list mode, a detail mode, the
  parent view of a detail buffer and the keys.
- `gitlab-read.el`: completion of IDs, projects and groups.
- `gitlab-export.el`: JSON export of the current display buffer.
- `gitlab-evil.el`: optional evil key layer.
- `ol-gitlab.el`: optional Org link types.
- `gitlab-xref.el`: optional xref backend.
- `test/`: `*-test.el` suites, `mock-glab`, the helper library and
  `fixtures/`.
- `flake.nix`: package, checks, dev shell, treefmt.

## Build and test

- `nix flake check`: package, checkdoc, package-lint, treefmt.  Run it
  before a commit.
- `nix build`: the package.  Its check phase byte-compiles every file
  with warnings as errors and runs the ERT suite.
- `nix develop -c emacs`: fast loop.  The shell carries evil, magit,
  magit-section, glab and git.
- `nix fmt`: nixfmt through treefmt.  Never run nixfmt directly.

## Architecture

One call chain, one direction:

    glab process -> gitlab-cli -> gitlab-data -> gitlab-mode
                 -> resource family -> gitlab-modes

### Transport

`gitlab-cli` owns the process, the argument list, the project spelling
and the JSON decode.  It owns no cache and no display state.

### Data

`gitlab-data` owns one entry point per resource, the list cache and the
write entry points.  It opens no buffer, reads no buffer-local variable
and loads no mode library.  A consumer that requires it gets the data
alone.

### Display

`gitlab-mode` owns both base modes, the Magit section tree, the table
and the asynchronous refresh pipeline.  It also owns the point record,
the faces, the buttons, the text links, the navigation and the
bookmark records.  A resource family adds a mode body, a fetch
function, an inserter hook and a buffer namer.

### Optional layers

`gitlab-evil`, `ol-gitlab` and `gitlab-xref` stay out of the entry
library.  Each one registers itself at its own load.

## Rules

- Load direction runs down only.  `gitlab-cli` requires neither
  `gitlab-data` nor `gitlab-mode`, and `gitlab-data` requires no mode
  library.
- A mode never builds a glab command and never reads `gitlab-program`.
  Every read uses a data entry point, so the planned `api` backend
  stays a transport swap.
- Every read carries a synchronous and an asynchronous form.  A prompt
  and a test use the synchronous one, a display buffer the
  asynchronous one.  A fetch function returns its process object, so
  `gitlab--kill-pending` cancels it.
- JSON stays a raw alist with symbol keys.  Read it with
  `gitlab-data-field` and merge a missing key with
  `gitlab-data-set-field`.  `:false` is JSON false, nil is JSON null.
- A write uses `gitlab--write` or `gitlab--write-async` with PARSE
  `text`.  It names its own CONTEXT and asks `yes-or-no-p` when the
  target sits outside the current detail buffer.
- A command that acts on one object takes it from
  `gitlab--object-at-point`.  The precedence is the text property at
  point, the identity of the display buffer, the web URL at point.  A
  target of another kind signals a user error.
- One context spelling names one project: `PATH` on
  `gitlab-cli-default-host`, `PATH@HOST` on another instance.  Buffer
  names, `list-buffers-directory`, bookmarks, Org links and xref
  identifiers all use it.  Do not add a second spelling.
- A display buffer carries `gitlab--identity`, a list of its mode, its
  object ID and its context.  Buffer lookup uses
  `gitlab--identity-buffer`, never a buffer name.
- Every display path calls `gitlab--use-project-directory` with the
  value of its caller and leaves `buffer-modified-p` nil.
- A render keeps point by the identity of a line, never by a buffer
  position.  `gitlab--render` records before the render and restores
  after it, so a renderer moves point freely.
- A renderer paints with `gitlab--propertize`.  Do not call
  `propertize` with `face` alone and do not call `font-lock-ensure`:
  both lose the paint of a Magit section buffer.
- Every face inherits a standard face and lives in `gitlab-mode.el`.  A
  new status face goes into `gitlab-status-faces`.
- An error signals a condition that derives from `gitlab-error`.  An
  asynchronous error callback receives a condition list, not a string.
- The cache serves prompts only.  A display buffer fetches fresh data
  on every refresh.
- `GLAB_NO_PROMPT=1` stays in the process environment, and a write that
  glab would confirm passes `--yes`.  A job trace stream keeps no
  timeout, a request keeps `gitlab-cli-timeout`.
- Byte-compilation warnings fail the build.  Fix the warning, do not
  silence it.
- Magit stays optional: the Git views call Magit functions, declare
  them with `declare-function`, and build no diff, commit or log
  buffer of their own.  Evil stays optional: `Package-Requires` names
  neither evil nor Magit.
- A new build input becomes a named argument of `gitlabModes` in
  `flake.nix`.

## Conventions

- Prefix a public symbol with `gitlab-` and an internal one with
  `gitlab--`.  `ol-gitlab.el` uses `gitlab-org-`.
- A helper that reads only its arguments declares `(declare (pure t)
  (side-effect-free t))`.  One that also reads a defcustom, a defconst
  or a buffer-local value declares `(declare (side-effect-free t))`
  alone.  One that touches a buffer, a process or a file declares
  nothing.
- Declare a function of another file with `declare-function` when the
  file does not require it.
- An interactive entry point carries a `;;;###autoload` cookie.
- A display mode passes `:interactive nil`.  A command that works in
  one mode names it in the `interactive` form, as
  `(interactive nil gitlab-detail-mode)`.  A command that resolves its
  target from `gitlab--object-at-point` names no mode.
  `gitlab-mode-command-modes` asserts the list.
- One hook per buffer kind lists its inserters in display order.  Add
  no second option that orders sections.
- Register a new field in the field list of the display layer
  (`gitlab-date-fields`, `gitlab-id-fields`, `gitlab-author-fields`,
  `gitlab-branch-fields`, `gitlab-tag-fields`) instead of testing a key
  name inside a renderer.
- Bind an evil key with `evil-define-minor-mode-key`.  A key that evil
  already owns becomes a `[remap EVIL-COMMAND]` vector.
- Write a function docstring in the imperative.  Write a variable
  docstring as a noun phrase.  Start a flag docstring with `When
  non-nil, ...`.  checkdoc enforces the form.

## Testing

- One `test/<unit>-test.el` per source unit.  A new unit adds a file,
  and the flake globs the tree.
- The suite runs offline.  `test/mock-glab` answers from
  `test/fixtures`, and no test opens a network connection.
- A new command and a changed behavior ship an ERT test.
  `gitlab-test-with-root` renders a section tree without the fetch
  pipeline.
- `test/gitlab-test-helper.el` holds the shared helpers.

## Dependencies

| package | required | why |
|---|---|---|
| Emacs 30.1 | required | floor of the section and table APIs in use |
| `magit-section` | required | the detail modes derive from `magit-section-mode` |
| `glab` | required | the transport shells out to it, and the build bakes in its store path |
| evil | optional | `gitlab-evil.el` and its suite only, never in `Package-Requires` |
| Magit | optional | the commit, changes and log views |
| Org | optional | `ol-gitlab.el` |

## Open work

- Keep the work in git-bug.  `git-bug bug` lists the issues of this
  repository, and an issue carries the design of a larger change.
- Add a native `api` transport.  The design sits in git-bug issue
  `cabdead`.
- List the job rows in the imenu of a pipeline buffer.  The design sits
  in git-bug issue `01e1ede`.
- Add list filters for state, scope, labels and author.
- Show merge request discussions one discussion at a time, not as one
  flat notes list.
- Add the pipeline actions retry, cancel and play.
- Add a detail buffer for a job with its metadata beside the log.

## Workflow

- Write the commit subject in the imperative, and name the file with a
  `file:` prefix when one file carries the change.  Put the reason in
  the body.
- Keep a generated file out of git.  `*.elc`, `*.eln`, `result*` and
  the ELPA directory stay ignored.
- Bump no version by hand.  The flake derives it from the commit date
  and passes it to `gitlabModes`.

# SketchUp bridge

Lets Claude Code run Ruby inside a running SketchUp, so that it can check how the API actually behaves, inspect the model, and try out changes, rather than guessing.

It is a development tool, for use while working on an extension. Nothing here is part of the extension itself.

## Setup

1. Start SketchUp with the bridge, using the **Launch SketchUp for debugging, with Claude bridge** task, or:

   ```sh
   ruby tools/debug-sketchup.rb 2026 --bridge
   ```

   The Ruby Console shows `SketchUp bridge: listening on 127.0.0.1:7200`. The debugger is started as well, so you can still attach to SketchUp as described in [DEBUGGING.md](../../DEBUGGING.md).

   The viewport gets an orange frame with the text "Claude bridge active: this model may be changed or cleared". See [Whose model it is](#whose-model-it-is).

2. Start Claude Code in the project. It asks whether to enable the `sketchup-bridge` MCP server from `.mcp.json`. Once you approve it, Claude has two tools: `evaluate_ruby`, and `run_tests` for running TestUp tests.

The MCP server needs Ruby 2.7 or newer on `PATH`, and no gems. Claude Code can be started before or after SketchUp. If SketchUp isn't running, the tool reports that instead of failing.

## From a terminal

`client.rb` sends code to the bridge and prints the result:

```sh
ruby tools/sketchup-bridge/client.rb "Sketchup.active_model.entities.size"
ruby tools/sketchup-bridge/client.rb < script.rb
```

On an error it prints the message and backtrace to stderr, and exits with status 1.

## How the code runs

- On SketchUp's main thread, at top level, like the Ruby Console. Local variables persist between calls.
- The value of the last expression is returned as `inspect` shows it. Anything written to `$stdout` or `$stderr` while the code runs is returned with it, instead of appearing in the Ruby Console.
- SketchUp is frozen until the code finishes.
- Exceptions are reported back, including syntax errors, and `exit` doesn't close SketchUp.

## Whose model it is

The SketchUp that the bridge runs in looks like any other, and you can work in it. But code sent through the bridge runs in whatever model is active, and tests may clear it. Two things guard against a model of your own getting in the way.

**A frame in the viewport, for you.** While the bridge is running, the viewport has a thin orange frame, and one line of text at the top. It is there so that you don't open your own work in that SketchUp by mistake. It is an overlay, named **SketchUp Bridge** in the Overlays panel, and it is added to every model you create or open. You can switch it off there, for instance when it is in the way of what you are testing. It then stays off in the models you create or open afterwards, and comes back the next time SketchUp is started with the bridge. A SketchUp started without `--bridge` never shows it.

**A notice in every reply, for Claude.** Every reply says which model is active: its file, or that it hasn't been saved to one, and whether it has unsaved changes. When the active model is not the one the previous call left, the reply starts with a warning. That happens when a model was created, opened or switched to outside the bridge, which is what it looks like when you open a model of your own. Claude is told to ask before changing such a model, and `run_tests` refuses to run in it. A model that the code itself creates or opens gives no warning.

## Running TestUp tests

`run_tests` runs a [TestUp](https://github.com/SketchUp/testup-2) test suite in SketchUp, and reports each failure, error and skip with its message and location. It needs TestUp 2.6 or newer installed in that SketchUp. It doesn't need TestUp's window, and doesn't install any gems.

- **Suite:** the folder holding the `TC_*.rb` files, such as `tests/Cube Example`.
- **Tests:** test cases or single tests, such as `TC_Main` or `TC_Main#test_create_cube`, with or without their namespace. By default the whole suite runs. A name that matches no test is reported as an error.
- **Reload:** folders or files of extension code to `load` again before running, such as `src/ex_hello_cube`. TestUp loads the test files again on every run, but not the code they test, so without this the tests keep running against the code SketchUp loaded at startup. The extension itself is expected to be loaded already.
- **Seed:** the Minitest seed, which is reported with every run, so that an order-dependent failure can be repeated.

Tests run in the active model, and many start by clearing it. So `run_tests` refuses to run in two cases, and Claude then asks before overriding the refusal:

- **The model has unsaved changes**, unless the only changes since the previous run were made by the tests. Overridden with `discard_model_changes`.
- **The model was created, opened or switched to outside the bridge**, even when it has no unsaved changes. A model you opened from a file would be emptied in SketchUp, and saving it after that would lose its contents. Overridden with `accept_switched_model`, once for that model.

A test that opens a model file, while the current one has unsaved changes, makes SketchUp ask whether to save them. SketchUp is frozen until that is answered. Tests usually close the model first, with `model.close(true)`.


## Files

| File             | Runs in     | Purpose                                                                      |
| ---------------- | ----------- | ---------------------------------------------------------------------------- |
| `server.rb`      | SketchUp    | Listens for code and evaluates it                                            |
| `model_watch.rb` | SketchUp    | Keeps track of which model is active, for the notice in every reply          |
| `overlay.rb`     | SketchUp    | The frame in the viewport                                                    |
| `mcp_server.rb`  | Claude Code | Provides the `evaluate_ruby` and `run_tests` tools, through the bridge       |
| `run_tests.rb`   | SketchUp    | The part of `run_tests` that runs inside SketchUp; loaded again on every run |
| `client.rb`      | Terminal    | Sends code from the command line; used by `mcp_server.rb`                    |

## Protocol

Connect to `127.0.0.1:7200`, send the code as UTF-8, then close the sending side of the connection. The bridge replies with one JSON object and closes the connection:

```json
{ "success": true, "result": "42", "output": "hello\n", "model": { "title": "", "path": "", "modified": false }, "model_changed": false }
{ "success": false, "error": "NameError: undefined local variable or method 'x' for main", "backtrace": ["(bridge):1:in '<main>'"], "output": "", "model": { "title": "House", "path": "C:\\Models\\House.skp", "modified": true }, "model_changed": true }
```

- `model` describes the active model once the code has run. `title` and `path` are empty for a model that hasn't been saved to a file, and `modified` tells whether it has unsaved changes. It is `null` when no model is open, which can happen on macOS.
- `model_changed` is `true` when the active model is not the one the previous request left, so when it was created, opened or switched to outside the bridge. It is `true` in one reply only. The first request after SketchUp starts has nothing to compare with, and always gets `false`.
- A request that is refused without running anything, such as an HTTP request, gets neither.

`client.rb` prints the result to stdout as before, and what the reply says about the model to stderr. The tools that Claude uses put it in the tool result: the warning first, and the active model last.

Results and output are cut off at 50,000 characters. A connection that hasn't finished sending after 30 seconds is closed.

## Limitations

- **One SketchUp at a time.** The port is fixed, so a second SketchUp started with the bridge reports that the port is in use.
- **Not while code is running.** The bridge doesn't answer while SketchUp is busy, including while a modal dialog is open.
- **The notice comes after the fact.** `evaluate_ruby` runs the code it is given in whatever model is active. A reply that warns that the model changed means the code already ran in the new model. Only `run_tests` refuses.
- **The notice can't tell who switched the model.** It only knows that it didn't happen while code from the bridge was running. A switch that such code sets off for later, with a timer for instance, counts as made outside the bridge.
- **The first request has nothing to compare with.** A model you open before Claude's first call is reported like any other, by its path, without a warning.
- **The frame needs SketchUp 2023 or newer**, which is when overlays were added. Older versions run the bridge without it. It isn't in images written with `view.write_image`.
- **Anyone on this machine can run code in SketchUp while the bridge is running.** It only listens on `127.0.0.1` and refuses HTTP requests, so other machines and web pages can't reach it, but there is no authentication. That's the same as the debugger, and the reason neither is started unless you ask for it.

## Why it works this way

SketchUp only runs one `-RubyStartup` file, so when the bridge is started, `server.rb` is that file and it loads the debugger's bootstrap itself.

SketchUp holds Ruby's global VM lock while it is idle, so Ruby threads in SketchUp barely run. Instead of a thread, the bridge uses a `UI.start_timer` on the main thread to check for connections without blocking, which is also where the SketchUp API has to be called from. That answers a request in a few tens of milliseconds, where a thread took seconds.

On Windows, up to SketchUp 2026, `Sketchup.active_model` is the same Ruby object after File > New or File > Open, and the observers on the previous model are gone. So the bridge counts the models that are created and opened, with an app observer, to tell that the model is another one. On macOS, and on Windows from SketchUp 2027, several models can be open, each with its own object, and comparing the objects tells when the user has switched between them.

SketchUp gives a newly added overlay the state that the previous overlay with the same id was left in. The bridge only switches the first frame on, which is how a frame you switched off stays off in the models that follow.

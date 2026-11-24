# SketchUp bridge

Lets an AI agent, such as Claude Code, run Ruby inside a running SketchUp instance, so that it can check how the API actually behaves, inspect the model, and try out changes, rather than guessing.

It is a development tool, for use while working on an extension. Nothing here is part of the extension itself.

## Prerequisites

- **Ruby 2.7 or newer on `PATH`**, for the launcher and the MCP server. No gems are needed.
- **SketchUp 2024 or newer.**
- **Your extension, loaded by SketchUp when it starts**, from the source folder you work in. The recommended way is [Extension Sources](https://github.com/thomthom/extension-sources): install it, and add the folder that holds your extension's registration file, such as this project's `src`, in its dialog. Any other way of loading the extension works too. The bridge only looks at whether it is loaded.
- **For `run_tests`: [TestUp](https://github.com/SketchUp/testup-2) 2.6 or newer**, also loaded when SketchUp starts. Install the RBZ from its [Releases page](https://github.com/SketchUp/testup-2/releases) once 2.6 is there. As of November 2026 the newest tagged version is 2.5.4, and 2.6 is on the `dev/api-for-tools` branch. Until it is released, clone the repository, check out that branch, set it up from source as TestUp's README describes, and add the clone's `src` folder in Extension Sources.

When TestUp or the extension isn't loaded, `run_tests` says so, and gives these steps. An agent is told to guide you through them, and to ask before it does anything itself. It may offer to clone a repository. It is told not to edit your Extension Sources list or other SketchUp settings.

**Trying it before setting up.** The agent can load TestUp or your extension into the running instance with `evaluate_ruby`, for instance `$LOAD_PATH << 'C:/path/to/testup-2/src'; require 'testup'`. That lasts until SketchUp closes, and has to be done again every time. It is for a first try, and no replacement for the setup above.

## Setup

1. Start SketchUp with the bridge, using the **Launch SketchUp for debugging, with AI agent bridge** task, or:

   ```sh
   ruby tools/debug-sketchup.rb 2026 --bridge
   ```

   The Ruby Console shows `SketchUp bridge: listening on 127.0.0.1:7200`. The debugger is started as well, so you can still attach to SketchUp as described in [DEBUGGING.md](../../DEBUGGING.md).

   The viewport gets an orange frame with the text "AI agent may change this model". See [Whose model it is](#whose-model-it-is).

2. Start your AI agent in the project. Claude Code reads `.mcp.json`, and asks whether to enable the `sketchup-bridge` MCP server. For another agent, register `ruby tools/sketchup-bridge/mcp_server.rb` as an MCP server that runs over stdio, with the project as its working directory. The agent then has two tools: `evaluate_ruby`, and `run_tests` for running TestUp tests.

The agent can be started before or after SketchUp. If SketchUp isn't running, the tool reports that instead of failing. So far the bridge has only been used with Claude Code.

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

The SketchUp instance that the bridge runs in looks like any other, and you can work in it. But code sent through the bridge runs in whatever model is active, and tests may clear it. Two things guard against a model of your own getting in the way.

**A frame in the viewport, for you.** While the bridge is running, the viewport has a thin orange frame, and one line of text at the top. It is there so that you don't open your own work in that instance by mistake. It is an overlay, named **SketchUp Bridge** in the Overlays panel, and it is added to every model you create or open. You can switch it off there, for instance when it is in the way of what you are testing. It then stays off in the models you create or open afterwards, and comes back the next time SketchUp is started with the bridge. An instance started without `--bridge` never shows it.

**A notice in every reply, for the agent.** Every reply says which model is active: its file, or that it hasn't been saved to one, and whether it has unsaved changes.

**A refusal when the model was switched.** When the active model is not the one the previous call left, the bridge doesn't run the code. It replies that the model was switched, and that the user should be asked first. That happens when a model was created, opened or switched to outside the bridge, which is what it looks like when you open a model of your own. Only that one call is refused: the same code runs when it is sent again, so tell the agent to go on if the model is one it may work in. `run_tests` goes on refusing until it is told that the model is accepted. A model that the code itself creates, opens or closes is never refused, so the agent can still work with several models.

## Running TestUp tests

`run_tests` runs a [TestUp](https://github.com/SketchUp/testup-2) test suite in SketchUp, and reports each failure, error and skip with its message and location. It needs TestUp 2.6 or newer loaded in that instance; see [Prerequisites](#prerequisites). It doesn't need TestUp's window, and doesn't install any gems.

- **Suite:** the folder holding the `TC_*.rb` files, such as `tests/Cube Example`.
- **Tests:** test cases or single tests, such as `TC_Main` or `TC_Main#test_create_cube`, with or without their namespace. By default the whole suite runs. A name that matches no test is reported as an error.
- **Reload:** folders or files of extension code to `load` again before running, such as `src/ex_hello_cube`. TestUp loads the test files again on every run, but not the code they test, so without this the tests keep running against the code SketchUp loaded at startup. The extension has to be loaded already. `run_tests` checks that Ruby has loaded code from these folders, however it got loaded, and says how to set the extension up when it hasn't. Without `reload` it can't tell which extension the tests are for. If tests then fail on a constant or a file that isn't found, the result adds a hint to pass the extension's folder here.
- **Seed:** the Minitest seed, which is reported with every run, so that an order-dependent failure can be repeated.

Tests run in the active model, and many start by clearing it. So `run_tests` refuses to run in two cases, and the agent is told to ask you before overriding the refusal:

- **The model has unsaved changes**, unless the only changes since the previous run were made by the tests. Overridden with `discard_model_changes`.
- **The model was created, opened or switched to outside the bridge**, even when it has no unsaved changes. A model you opened from a file would be emptied in SketchUp, and saving it after that would lose its contents. Overridden with `accept_switched_model`, once for that model. Unlike `evaluate_ruby`, sending the same call again doesn't override it.

A test that opens a model file, while the current one has unsaved changes, makes SketchUp ask whether to save them. SketchUp is frozen until that is answered. Tests usually close the model first, with `model.close(true)`.


## Files

| File             | Runs in     | Purpose                                                                      |
| ---------------- | ----------- | ---------------------------------------------------------------------------- |
| `server.rb`      | SketchUp    | Listens for code and evaluates it                                            |
| `model_watch.rb` | SketchUp    | Keeps track of which model is active, for the notice in every reply          |
| `overlay.rb`     | SketchUp    | The frame in the viewport                                                    |
| `mcp_server.rb`  | The agent   | Provides the `evaluate_ruby` and `run_tests` tools, through the bridge       |
| `run_tests.rb`   | SketchUp    | The part of `run_tests` that runs inside SketchUp; loaded again on every run |
| `client.rb`      | Terminal    | Sends code from the command line; used by `mcp_server.rb`                    |

## Protocol

Connect to `127.0.0.1:7200`, send the code as UTF-8, then close the sending side of the connection. The bridge replies with one JSON object and closes the connection:

```json
{ "success": true, "result": "42", "output": "hello\n", "model": { "title": "", "path": "", "modified": false }, "model_changed": false }
{ "success": false, "error": "NameError: undefined local variable or method 'x' for main", "backtrace": ["(bridge):1:in '<main>'"], "output": "", "model": { "title": "", "path": "", "modified": false }, "model_changed": false }
{ "success": false, "error": "Not run: the active model in SketchUp is not the one the previous request left. ...", "backtrace": [], "output": "", "model": { "title": "House", "path": "C:\\Models\\House.skp", "modified": true }, "model_changed": true }
```

- `model` describes the active model once the code has run. `title` and `path` are empty for a model that hasn't been saved to a file, and `modified` tells whether it has unsaved changes. It is `null` when no model is open, which can happen on macOS.
- `model_changed` is `true` when the active model is not the one the previous request left, so when it was created, opened or switched to outside the bridge. The code is then not run: `success` is `false`, and `error` says why. It is `true` in one reply only, so the same request runs when it is sent again. The first request after SketchUp starts has nothing to compare with, and always gets `false`.
- A request that isn't valid, such as an HTTP request, gets neither.

`client.rb` prints the result to stdout as before, and the active model to stderr. The `evaluate_ruby` and `run_tests` tools end their result with it.

Results and output are cut off at 50,000 characters. A connection that hasn't finished sending after 30 seconds is closed.

## Limitations

- **One instance at a time.** The port is fixed, so a second SketchUp instance started with the bridge reports that the port is in use.
- **Not while code is running.** The bridge doesn't answer while SketchUp is busy, including while a modal dialog is open.
- **The refusal is a question, not a lock.** After a model is switched, one call is refused, and the agent is told to ask you. Nothing stops the same call from being sent again.
- **The bridge can't tell who switched the model.** It only knows that it didn't happen while code from the bridge was running. A switch that such code sets off for later, with a timer for instance, counts as made outside the bridge.
- **The first request has nothing to compare with.** A model you open before the agent's first call is reported like any other, by its path, and code runs in it.
- **The frame needs SketchUp 2023 or newer**, which is when overlays were added. Older versions run the bridge without it. It isn't in images written with `view.write_image`.
- **Anyone on this machine can run code in SketchUp while the bridge is running.** It only listens on `127.0.0.1` and refuses HTTP requests, so other machines and web pages can't reach it, but there is no authentication. That's the same as the debugger, and the reason neither is started unless you ask for it.

## Why it works this way

SketchUp only runs one `-RubyStartup` file, so when the bridge is started, `server.rb` is that file and it loads the debugger's bootstrap itself.

SketchUp holds Ruby's global VM lock while it is idle, so Ruby threads in SketchUp barely run. Instead of a thread, the bridge uses a `UI.start_timer` on the main thread to check for connections without blocking, which is also where the SketchUp API has to be called from. That answers a request in a few tens of milliseconds, where a thread took seconds.

On Windows, up to SketchUp 2026, `Sketchup.active_model` is the same Ruby object after File > New or File > Open, and the observers on the previous model are gone. So the bridge counts the models that are created and opened, with an app observer, to tell that the model is another one. On macOS, and on Windows from SketchUp 2027, several models can be open, each with its own object, and comparing the objects tells when the user has switched between them.

SketchUp gives a newly added overlay the state that the previous overlay with the same id was left in. The bridge only switches the first frame on, which is how a frame you switched off stays off in the models that follow.

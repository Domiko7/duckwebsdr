Vendored plugin
===============

`frequency_far_jump.js` is a local copy of the OpenWebRX+ plugin

  https://0xaf.github.io/openwebrxplus-plugins/receiver/frequency_far_jump/frequency_far_jump.js

License: Apache License 2.0, Copyright (c) 2024 Dimitar Milkov, LZ2DMV.

The only change from upstream is that its `utils` dependency is loaded from the
local copy in `../utils/` instead of the upstream website, so the receiver UI
does not need to fetch third-party JavaScript at page load.

`../utils/utils.js` is the matching upstream utils plugin (v0.9, MIT, Copyright
(c) 2023-2026 Stanislav Lechev [0xAF], LZ2SLL). It is required by
`frequency_far_jump`, which passes a `null` after-callback to `wrap_func()`.
Older utils versions (v0.1 as originally bundled here) do not guard that call
and throw.

To update, re-download both files from the upstream plugin repository and
re-apply the one-line `Plugins.load('utils')` change in `frequency_far_jump.js`.

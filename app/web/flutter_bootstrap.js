{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Flutter 3.47's CanvasKit image sources can be cleared when covers remount
    // (flutter/flutter#191800). Use skwasm on Firefox as well as Chromium.
    // The loader still checks WasmGC/WebGL support before selecting this build.
    wasmAllowList: { gecko: true },
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});

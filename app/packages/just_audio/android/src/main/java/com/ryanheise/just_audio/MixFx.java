package com.ryanheise.just_audio;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** The players' mix processors by player id, and the method channel the app drives them with. */
final class MixFx implements MethodChannel.MethodCallHandler {
    private static final Map<String, MixFxProcessor> processors = new HashMap<>();

    static synchronized void register(String playerId, MixFxProcessor processor) {
        processors.put(playerId, processor);
    }

    static synchronized void unregister(String playerId) {
        processors.remove(playerId);
    }

    private static synchronized MixFxProcessor get(String playerId) {
        return processors.get(playerId);
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        String id = call.argument("id");
        MixFxProcessor processor = id == null ? null : get(id);
        if (processor == null) {
            result.success(false);
            return;
        }
        switch (call.method) {
            case "set":
                processor.setAutomation(automation(call));
                result.success(true);
                break;
            case "clear":
                processor.clearAutomation();
                result.success(true);
                break;
            case "position":
                result.success(processor.position());
                break;
            default:
                result.notImplemented();
        }
    }

    private static MixFxProcessor.Automation automation(MethodCall call) {
        MixFxProcessor.Automation a = new MixFxProcessor.Automation();
        a.startUs = ((Number) call.argument("startUs")).longValue();
        a.stepUs = Math.max(1000, ((Number) call.argument("stepUs")).longValue());
        List<?> values = call.argument("values");
        for (int p = 0; p < MixFxProcessor.PARAMS; p++) {
            List<?> list = (List<?>) values.get(p);
            float[] v = new float[Math.max(1, list.size())];
            for (int i = 0; i < list.size(); i++) v[i] = ((Number) list.get(i)).floatValue();
            a.values[p] = v;
        }
        a.echoDelaySeconds = ((Number) call.argument("echoDelay")).doubleValue();
        a.echoFeedback = ((Number) call.argument("echoFeedback")).doubleValue();
        Number loopAt = call.argument("loopAtUs");
        a.loopAtUs = loopAt == null ? -1 : loopAt.longValue();
        Number loopSeconds = call.argument("loopSeconds");
        a.loopSeconds = loopSeconds == null ? 0 : loopSeconds.doubleValue();
        return a;
    }
}

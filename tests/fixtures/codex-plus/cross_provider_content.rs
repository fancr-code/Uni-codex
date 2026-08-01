use codex_plus_core::{
    assets, compatibility_notice, diagnostic_log, protocol_proxy::responses_to_chat_completions,
    settings::BackendSettings,
};
use serde_json::{Value, json};
use std::sync::{Mutex, MutexGuard, OnceLock};

fn test_guard() -> MutexGuard<'static, ()> {
    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .expect("cross-provider test lock")
}

fn assert_chat_content_invariant(converted: &Value) {
    for (index, message) in converted["messages"]
        .as_array()
        .expect("converted messages")
        .iter()
        .enumerate()
    {
        let content = message.get("content").expect("message content");
        assert!(
            content.is_string() || content.is_array(),
            "messages[{index}].content must be string or list: {content}"
        );
    }
}

#[test]
fn cross_provider_history_content_is_compatible_and_private() {
    let _guard = test_guard();
    let temp = tempfile::tempdir().unwrap();
    let log = temp.path().join("codex-plus.log");
    let notice = temp.path().join("compatibility-notice.json");
    diagnostic_log::set_diagnostic_log_path_for_tests(Some(log.clone()));
    compatibility_notice::set_notice_path_for_tests(Some(notice));

    let deepseek = responses_to_chat_completions(json!({
        "model": "gpt-5.6",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": {"type": "input_text", "text": "继续处理 DeepSeek 里的任务"}
            },
            {
                "type": "message",
                "role": "assistant",
                "content": {"type": "output_text", "text": "保留这段回答"}
            }
        ]
    }))
    .unwrap();
    assert_chat_content_invariant(&deepseek);
    assert_eq!(
        deepseek["messages"][0]["content"],
        "继续处理 DeepSeek 里的任务"
    );
    assert_eq!(deepseek["messages"][1]["content"], "保留这段回答");

    let private_marker = "PRIVATE-CONTENT-MUST-NOT-BE-LOGGED";
    let kimi = responses_to_chat_completions(json!({
        "model": "gpt-5.6",
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": {"future_block": {"value": 7, "private": private_marker}}
            },
            {"type": "message", "role": "assistant", "content": true},
            {"type": "message", "role": "user", "content": 42}
        ]
    }))
    .unwrap();
    assert_chat_content_invariant(&kimi);
    assert!(
        kimi["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("future_block")
    );
    assert_eq!(kimi["messages"][1]["content"], "true");
    assert_eq!(kimi["messages"][2]["content"], "42");

    for model in ["deepseek-chat", "kimi-k2.5"] {
        let converted = responses_to_chat_completions(json!({
            "model": model,
            "input": [{
                "type": "message",
                "role": "assistant",
                "content": {"type": "output_text", "text": "GPT 会话中的回答"}
            }]
        }))
        .unwrap();
        assert_chat_content_invariant(&converted);
        assert_eq!(converted["messages"][0]["content"], "GPT 会话中的回答");
    }

    let edges = responses_to_chat_completions(json!({
        "model": "deepseek-chat",
        "input": [
            {"type": "message", "role": "assistant", "content": null},
            {
                "type": "message",
                "role": "user",
                "content": [
                    {"type": "input_text", "text": "看图"},
                    {"type": "input_image", "image_url": "data:image/png;base64,AA=="}
                ]
            },
            {
                "type": "function_call",
                "call_id": "call_1",
                "name": "lookup",
                "arguments": "{}"
            },
            {
                "type": "function_call_output",
                "call_id": "call_1",
                "output": "tool result"
            },
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "future_part", "payload": {"answer": 7}}]
            }
        ]
    }))
    .unwrap();
    assert_chat_content_invariant(&edges);
    let messages = edges["messages"].as_array().unwrap();
    assert_eq!(messages[0]["content"], "");
    assert!(
        messages[1]["content"]
            .as_array()
            .unwrap()
            .iter()
            .any(|part| part["type"] == "image_url")
    );
    assert!(
        messages
            .iter()
            .any(|message| message.get("tool_calls").is_some())
    );
    assert!(
        messages
            .iter()
            .any(|message| { message["role"] == "tool" && message["tool_call_id"] == "call_1" })
    );
    assert!(
        messages.last().unwrap()["content"]
            .as_str()
            .unwrap()
            .contains("future_part")
    );

    let log_text = std::fs::read_to_string(log).unwrap();
    assert!(log_text.contains("protocol_proxy.content_compatibility"));
    assert!(log_text.contains("\"object\""));
    assert!(!log_text.contains(private_marker));
    let _ = compatibility_notice::take_content_repair_notice().unwrap();
    compatibility_notice::set_notice_path_for_tests(None);
    diagnostic_log::set_diagnostic_log_path_for_tests(None);
}

#[test]
fn compatibility_notice_is_private_and_taken_once() {
    let _guard = test_guard();
    let temp = tempfile::tempdir().unwrap();
    let marker = temp.path().join("compatibility-notice.json");
    compatibility_notice::set_notice_path_for_tests(Some(marker.clone()));

    compatibility_notice::record_content_repair(2).unwrap();
    let disk = std::fs::read_to_string(&marker).unwrap();
    assert!(disk.contains("\"repairedMessageCount\":2"));
    assert!(!disk.contains("PRIVATE-CONTENT-MUST-NOT-BE-LOGGED"));

    let first = compatibility_notice::take_content_repair_notice()
        .unwrap()
        .unwrap();
    assert_eq!(first.repaired_message_count, 2);
    assert!(
        compatibility_notice::take_content_repair_notice()
            .unwrap()
            .is_none()
    );
    compatibility_notice::set_notice_path_for_tests(None);
}

#[test]
fn macos_dream_skin_observer_avoids_style_feedback_loops() {
    let script = assets::injection_script_with_settings(57321, &BackendSettings::default());
    let expected_filter =
        r#"attributeFilter: ["class", "data-theme", "data-appearance", "data-color-mode"]"#;
    let legacy_filter = r#"attributeFilter: ["class", "data-theme", "data-appearance", "data-color-mode", "style"]"#;

    assert!(script.contains(expected_filter));
    assert!(!script.contains(legacy_filter));
}

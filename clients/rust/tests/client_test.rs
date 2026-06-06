use serde_json::json;
use std::path::PathBuf;
use zmr_client::{Client, Error, TraceDiscoverOptions};

fn fake_server_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fake-json-rpc-server.mjs")
}

#[test]
fn client_drives_fake_session() {
    let server = fake_server_path();
    let mut client = Client::start("node", [server.to_string_lossy().to_string()]).unwrap();

    let capabilities = client.capabilities().unwrap();
    assert_eq!(capabilities.protocol_version, "2026-04-28");
    assert!(capabilities
        .methods
        .iter()
        .any(|method| method == "observe.snapshot"));
    assert!(capabilities
        .methods
        .iter()
        .any(|method| method == "assert.healthy"));
    assert!(!capabilities.ios_preview);
    let ios_support = capabilities.platform_support.get("ios").unwrap();
    assert_eq!(ios_support.status, "supported");
    assert_eq!(ios_support.device_types, vec!["simulator", "physical"]);
    assert!(ios_support.physical_devices);

    let session = client.create_session().unwrap();
    assert_eq!(session.session_id, "default");
    assert!(client.close_session().unwrap());

    let devices = client.devices().unwrap();
    assert_eq!(devices.len(), 2);
    assert_eq!(devices[0].serial, "fake-device-1");
    assert_eq!(devices[0].state, "device");
    assert!(devices[0].ready);
    assert_eq!(devices[1].serial, "fake-ios-disconnected");
    assert_eq!(devices[1].state, "disconnected");
    assert!(!devices[1].ready);

    assert!(client.open_link("exampleapp://rust-client").unwrap());
    assert!(client.launch().unwrap());
    assert!(client.stop().unwrap());
    assert!(client.clear_state().unwrap());
    assert!(client.tap(json!({ "text": "Home" })).unwrap());
    assert!(client
        .type_text("agent@example.com", Some(json!({ "resourceId": "email" })))
        .unwrap());
    assert!(client
        .erase_text(Some(json!({ "resourceId": "email" })), Some(32))
        .unwrap());
    assert!(client.hide_keyboard().unwrap());
    assert!(client.swipe(10, 100, 10, 20, Some(250)).unwrap());
    assert!(client.press_back().unwrap());
    assert!(client
        .scroll_until_visible(json!({ "text": "Settings" }), Some("down"), Some(1000))
        .unwrap());
    assert!(client
        .wait_until(json!({ "text": "Home" }), Some(1000))
        .unwrap());
    assert!(client
        .wait_any(
            vec![json!({ "text": "Home" }), json!({ "text": "Dashboard" })],
            Some(1000)
        )
        .unwrap());
    assert!(client
        .wait_gone(json!({ "text": "Loading" }), Some(1000))
        .unwrap());
    assert!(client
        .assert_visible(json!({ "text": "Home" }), Some(1000))
        .unwrap());
    assert!(client
        .assert_not_visible(json!({ "text": "Application has crashed" }), Some(1000))
        .unwrap());
    assert!(client.assert_healthy(Some(1000)).unwrap());

    let snapshot = client.snapshot().unwrap();
    assert_eq!(snapshot.active_package, "com.example.mobiletest");
    assert_eq!(snapshot.nodes[0].text.as_deref(), Some("Home"));

    let semantic_snapshot = client.semantic_snapshot().unwrap();
    assert_eq!(semantic_snapshot.nodes[0].role, "button");
    assert_eq!(
        semantic_snapshot.nodes[0].recommended_action.as_deref(),
        Some("tap")
    );

    let exported = client
        .export_trace("traces/rust-client.zmrtrace", true, true)
        .unwrap();
    assert!(exported.redacted);
    assert!(exported.omit_screenshots);

    let events = client.trace_events(0, Some(10)).unwrap();
    assert_eq!(events.next_seq, 2);
    assert_eq!(events.events[0]["kind"], "rpc.request");

    let discovered = client
        .discover_trace(
            ".zmr/discovered/rust-client.json",
            TraceDiscoverOptions {
                include_actions: true,
                validate: true,
                force: true,
                name: Some("Rust discovery".to_string()),
                app_id: Some("com.example.rust".to_string()),
            },
        )
        .unwrap();
    assert!(discovered.ok);
    assert_eq!(discovered.mode, "discover");
    assert_eq!(discovered.out, ".zmr/discovered/rust-client.json");
    assert_eq!(discovered.app_id.as_deref(), Some("com.example.rust"));
    assert_eq!(discovered.replay.step_count, 1);
    assert!(discovered.validated);
    assert!(discovered.validation.as_ref().unwrap().ok);
    assert!(discovered.next_commands[0].contains("zmr validate --json"));

    let validation = client
        .validate_scenario(".zmr/discovered/rust-client.json")
        .unwrap();
    assert!(validation.ok);
    assert_eq!(validation.path, ".zmr/discovered/rust-client.json");
    assert_eq!(validation.step_count, 4);
    assert!(validation.next_commands[0].contains("zmr run"));
}

#[test]
fn client_returns_rpc_errors() {
    let server = fake_server_path();
    let mut client = Client::start("node", [server.to_string_lossy().to_string()]).unwrap();

    let err = client
        .request::<serde_json::Value>("missing.method", json!({}))
        .unwrap_err();
    match err {
        Error::Rpc(rpc) => {
            assert_eq!(rpc.code, -32601);
            assert_eq!(rpc.message, "method not found");
        }
        other => panic!("expected rpc error, got {other:?}"),
    }
}

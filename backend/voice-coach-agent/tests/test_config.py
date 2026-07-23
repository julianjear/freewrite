import pytest

from coach.config import (
    DEFAULT_PROFILE_ID,
    PROFILES,
    parse_metadata_config,
    parse_voice_config,
    rejected_metadata_config_detail,
)


def test_default_config_is_versioned_production_cascade():
    config = parse_voice_config(None)
    assert config.version == 1
    assert config.profile_id == DEFAULT_PROFILE_ID
    assert config.profile.architecture == "cascade"
    assert config.profile.model == "gemini-3.5-flash"
    assert config.turn_strategy == "livekit-audio"
    assert config.supervisor_interval_seconds == 30
    assert config.supervisor_effort == "high"


def test_every_profile_has_stable_matching_id():
    assert PROFILES
    assert all(key == profile.id for key, profile in PROFILES.items())


def test_parses_realtime_and_supervisor_controls():
    config = parse_voice_config({
        "version": 1,
        "profileId": "realtime-gpt-2.1",
        "reasoningEffort": "minimal",
        "supervisorEnabled": False,
        "supervisorModel": "gemini-3.5-flash",
        "supervisorEffort": "medium",
        "supervisorIntervalSeconds": 30,
        "observabilityEnabled": False,
        "turnStrategy": "livekit-audio",
    })
    assert config.profile.architecture == "realtime"
    assert config.reasoning_effort == "minimal"
    assert config.supervisor_enabled is False
    assert config.supervisor_interval_seconds == 30
    assert config.supervisor_effort == "medium"


@pytest.mark.parametrize("field,value", [
    ("profileId", "made-up-model"),
    ("reasoningEffort", "high"),
    ("supervisorModel", "made-up-supervisor"),
    ("supervisorIntervalSeconds", 25),
])
def test_rejects_unknown_values(field, value):
    body = {field: value}
    with pytest.raises(ValueError):
        parse_voice_config(body)


def test_rejects_flux_for_native_realtime():
    with pytest.raises(ValueError):
        parse_voice_config({
            "profileId": "realtime-gpt-2.1",
            "turnStrategy": "flux",
        })


@pytest.mark.parametrize("model", ["claude-sonnet-5", "claude-opus-4-8", "gpt-5.6-sol"])
def test_accepts_deep_strategists_and_max_effort(model):
    config = parse_voice_config({"supervisorModel": model, "supervisorEffort": "max"})
    assert config.supervisor_model == model
    assert config.supervisor_effort == "max"


def test_rejects_effort_not_supported_by_gemini():
    with pytest.raises(ValueError):
        parse_voice_config({"supervisorModel": "gemini-3.5-flash", "supervisorEffort": "xhigh"})


def test_metadata_rejects_valid_json_with_invalid_voice_config():
    with pytest.raises(ValueError, match="unsupported voice profile"):
        parse_metadata_config('{"voiceConfig":{"profileId":"made-up-model"}}')


@pytest.mark.parametrize("metadata", ["[]", '{"voiceConfig":"not-an-object"}'])
def test_metadata_rejects_structurally_invalid_config(metadata):
    with pytest.raises(ValueError):
        parse_metadata_config(metadata)


def test_metadata_without_voice_config_uses_default():
    config = parse_metadata_config('{"entryType":"text"}')
    assert config.profile_id == DEFAULT_PROFILE_ID


def test_rejected_metadata_reports_requested_selection_without_defaults():
    detail = rejected_metadata_config_detail(
        '{"voiceConfig":{"profileId":"made-up-model",'
        '"supervisorModel":"claude-opus-4-8","supervisorEffort":"max"}}'
    )
    assert detail == {
        "requestedProfileId": "made-up-model",
        "requestedSupervisorModel": "claude-opus-4-8",
        "requestedSupervisorEffort": "max",
    }

"""Tests of the base agent graph with a fake model (US-LANG-004)."""

import pytest
from langchain_core.language_models.fake_chat_models import FakeListChatModel

from ai_engine.graph import build_graph
from ai_engine.nodes import parse_severity


def test_graph_runs_triage_then_investigator() -> None:
    model = FakeListChatModel(responses=["high", "Posible saturación de conexiones."])
    graph = build_graph(model, context_provider=lambda state: "db: 85% conexiones")

    result = graph.invoke({"ticket_id": "T-1", "description": "La BD responde lento"})

    assert result["severity"] == "high"
    assert result["status"] == "investigated"
    assert len(result["agent_notes"]) == 2
    assert "saturación" in result["agent_notes"][1]
    assert len(result["messages"]) == 2


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("CRITICAL", "critical"), (" Low.", "low"), ("no idea", "medium")],
)
def test_parse_severity(raw: str, expected: str) -> None:
    assert parse_severity(raw) == expected


def test_compiled_graph_requires_model_env(monkeypatch: pytest.MonkeyPatch) -> None:
    import ai_engine.graph as graph_module

    monkeypatch.delenv("AI_MODEL_NAME", raising=False)
    with pytest.raises(RuntimeError, match="AI_MODEL_NAME"):
        graph_module.compiled_graph


_DEEPSEEK_ENV = {
    "AI_MODEL_NAME": "deepseek-chat",
    "DEEPSEEK_API_KEY": "sk-test",
    "DEEPSEEK_BASE_URL": "https://api.deepseek.example/v1",
}


def test_build_chat_model_targets_deepseek() -> None:
    from ai_engine.config import build_chat_model

    model = build_chat_model(_DEEPSEEK_ENV)

    assert model.model_name == "deepseek-chat"  # type: ignore[attr-defined]
    assert model.openai_api_base == "https://api.deepseek.example/v1"  # type: ignore[attr-defined]
    assert model.openai_api_key.get_secret_value() == "sk-test"  # type: ignore[attr-defined]


@pytest.mark.parametrize("missing", ["AI_MODEL_NAME", "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"])
def test_build_chat_model_requires_each_variable(missing: str) -> None:
    from ai_engine.config import build_chat_model

    env = {k: v for k, v in _DEEPSEEK_ENV.items() if k != missing}
    with pytest.raises(RuntimeError, match=missing):
        build_chat_model(env)

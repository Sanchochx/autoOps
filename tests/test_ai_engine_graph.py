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
    assert len(result["messages"]) == 99


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

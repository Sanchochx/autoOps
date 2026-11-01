"""AI engine configuration (Twelve-Factor).

The model, the provider endpoint and the API key come from environment variables.
The provider is DeepSeek, whose API is OpenAI-compatible, so ``ChatOpenAI`` is used
with an explicit key and base URL.
"""

import os
from collections.abc import Mapping

from langchain_core.language_models.chat_models import BaseChatModel
from langchain_openai import ChatOpenAI

REQUIRED_VARIABLES = ("AI_MODEL_NAME", "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL")


def build_chat_model(env: Mapping[str, str] | None = None) -> BaseChatModel:
    """Build the chat model from the environment.

    Requires ``AI_MODEL_NAME`` (e.g. ``deepseek-chat``), ``DEEPSEEK_API_KEY`` and
    ``DEEPSEEK_BASE_URL`` (e.g. ``https://api.deepseek.com/v1``).

    Args:
        env: variables to read (defaults to ``os.environ``).

    Raises:
        RuntimeError: naming the first required variable that is missing or empty.
    """
    values = os.environ if env is None else env
    for name in REQUIRED_VARIABLES:
        if not values.get(name):
            raise RuntimeError(f"La variable de entorno {name} no está definida")
    return ChatOpenAI(
        model=values["AI_MODEL_NAME"],
        api_key=values["DEEPSEEK_API_KEY"],
        base_url=values["DEEPSEEK_BASE_URL"],
    )

"""Which LLM every agent runs on, in one place. Set RQ_MODEL (env or .env) to a
litellm model string -- e.g. "groq/openai/gpt-oss-120b" or
"gemini/gemini-3.5-flash-lite" -- and put that provider's key (GROQ_API_KEY,
GEMINI_API_KEY, ...) beside it. Unset, it falls back to the local ollama model.
.env is loaded into the process environment on import so litellm sees the key."""

import os;

glob LOCAL_MODEL: str = "ollama_chat/huihui_ai/qwen3-coder-abliterated";

"""Copy KEY=VALUE lines from ./.env into os.environ without overriding values
already set by the real environment (hosting secrets win). Returns how many."""
def load_dotenv(path: str = ".env") -> int {
    if not os.path.isfile(path) {
        return 0;
    }
    n = 0;
    for line in open(path).read().splitlines() {
        s = line.strip();
        if not s or s.startswith("#") or "=" not in s {
            continue;
        }
        key = s.split("=", 1)[0].strip();
        val = s.split("=", 1)[1].strip().strip("\"'");
        if key and val and key not in os.environ {
            os.environ[key] = val;
            n += 1;
        }
    }
    return n;
}

def _model_name -> str {
    load_dotenv();
    return os.environ.get("RQ_MODEL", "") or LOCAL_MODEL;
}

glob LLM_MODEL: str = _model_name();

"""Let litellm retry transient failures (rate limits, dropped connections) with
backoff instead of failing the whole audit pass on one hiccup."""
def _enable_retries -> int {
    import litellm;
    litellm.num_retries = LLM_RETRIES;
    return LLM_RETRIES;
}

glob LLM_RETRIES: int = 3;
glob _RETRIES_SET: int = _enable_retries();

test "load_dotenv keeps real env values and skips comments" {
    p = "/tmp/rq-test.env";
    with open(p, "w") as fh {
        fh.write("# comment\nRQ_T_A=one\nRQ_T_B=\"two\"\nBAD LINE\nRQ_T_C=\n");
    }
    os.environ["RQ_T_A"] = "kept";
    assert load_dotenv(p) == 1;
    assert os.environ["RQ_T_A"] == "kept";
    assert os.environ["RQ_T_B"] == "two";
    assert "RQ_T_C" not in os.environ;
}

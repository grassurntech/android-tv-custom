"""Entry point so `unittest discover` picks up the generated script cases."""
try:
    from script_cases import ScriptCases  # noqa: F401  (tests/ is the discovery root)
except ImportError:
    from tests.script_cases import ScriptCases  # noqa: F401

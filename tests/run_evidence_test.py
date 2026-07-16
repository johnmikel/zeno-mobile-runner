"""Explicit aggregator for the non-discovered run-evidence case modules."""

import unittest

from tests.run_evidence_cases import (
    bundle,
    cli,
    command_materialization,
    command_state,
    command_supervisor,
    commands,
    contracts,
    journal,
    lifecycle,
    rooted_io,
    sanitization,
    session,
)


CASE_MODULES = (
    contracts,
    lifecycle,
    journal,
    rooted_io,
    sanitization,
    command_state,
    command_materialization,
    command_supervisor,
    session,
    commands,
    bundle,
    cli,
)


def load_tests(loader, _tests, _pattern):
    suite = unittest.TestSuite()
    for module in CASE_MODULES:
        suite.addTests(loader.loadTestsFromModule(module))
    return suite

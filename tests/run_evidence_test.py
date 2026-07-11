"""Explicit aggregator for the non-discovered run-evidence case modules."""

import unittest

from tests.run_evidence_cases import (
    bundle,
    cli,
    commands,
    contracts,
    journal,
    lifecycle,
    sanitization,
)


CASE_MODULES = (
    contracts,
    lifecycle,
    journal,
    sanitization,
    commands,
    bundle,
    cli,
)


def load_tests(loader, _tests, _pattern):
    suite = unittest.TestSuite()
    for module in CASE_MODULES:
        suite.addTests(loader.loadTestsFromModule(module))
    return suite

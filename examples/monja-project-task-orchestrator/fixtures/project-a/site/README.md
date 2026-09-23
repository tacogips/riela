# Project A site fixture

This separate directory is the exclusive `site` write scope. Tasks touching only
this directory may run alongside API tasks. A task touching both must declare
both scopes and wait for conflicts or merge after acknowledged cancellation.

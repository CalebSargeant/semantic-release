"""Throwaway file to smoke-test Diatreme Dispatch end-to-end (run 3). Safe to delete."""


def average(numbers):
    if not numbers:
        return 0
    return sum(numbers) / len(numbers)

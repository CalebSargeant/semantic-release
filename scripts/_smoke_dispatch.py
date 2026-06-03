"""Throwaway file to smoke-test Diatreme Dispatch end-to-end (run 2). Safe to delete."""


def average(numbers):
    if not numbers:
        raise ValueError("Cannot compute average of empty list")
    return sum(numbers) / len(numbers)

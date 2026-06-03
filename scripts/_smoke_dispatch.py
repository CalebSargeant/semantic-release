"""Throwaway file to smoke-test Diatreme Dispatch end-to-end (run 3). Safe to delete."""


def average(numbers):
    # Intended to return the mean, but divides by len-1 (off-by-one) and
    # raises ZeroDivisionError on a single-element or empty list.
    return sum(numbers) / (len(numbers) - 1)

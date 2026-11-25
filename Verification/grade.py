"""Compare the itinerary executor's values and cited photo IDs with the test bank."""
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent


def check_case(case, result):
    rows = result["rows"]
    summary = result.get("summary", "")
    sources = sorted(row["id"] for row in rows if "id" in row)
    documents = {}
    for row in rows:
        kind = row["kind"]
        if kind in documents:
            return False
        fields = (line.split(" · ", 1) for line in row["detail"].splitlines() if " · " in line)
        documents[kind] = dict(fields)

    if case["gold"]:
        notice = documents.get("Service update", {})
        ticket = documents.get("Rail ticket", {})
        interval = re.match(r"(\d+) minutes between", summary)
        actual = [
            notice.get("New Departure", ticket.get("Departure")),
            int(interval[1]) if interval else None,
            documents.get("Hotel confirmation", {}).get("Property"),
            notice.get("Platform", ticket.get("Platform")),
            sources,
        ]
        expected = case["gold"]
        return actual == [*expected[:4], sorted(expected[4])]

    control = case["control"]
    if control == "snapshot":
        board = documents.get("Departure board snapshot")
        return sources == ["M"] and board == {"Observed": "2027-08-12 23:58", "Platform": "5"}
    if sources:
        return False
    if control == "live":
        return "live train status" in summary
    if control == "ambiguous":
        return "Which rail booking" in summary or any("Several photos" in row["detail"] for row in rows)
    if control == "missing":
        return any("No matching photo" in row["detail"] for row in rows)
    raise ValueError(f"Unknown control: {control}")


def main():
    results_path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "swift-results.jsonl"
    cases = json.loads((HERE / "bank.json").read_text())
    results = [json.loads(line) for line in results_path.read_text().splitlines()]
    if not cases or [c["name"] for c in cases] != [r["name"] for r in results]:
        sys.exit("Result inventory differs from the test bank.")
    failed = [case["name"] for case, result in zip(cases, results) if not check_case(case, result)]
    for name in failed:
        print(f"FAIL {name}")
    print(f"{len(cases) - len(failed)}/{len(cases)} correct; {sum(r['called'] for r in results)} Nativ calls.")
    return bool(failed)


if __name__ == "__main__":
    sys.exit(main())

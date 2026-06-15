# Updated: 2026-06-15T16:56:48Z
def export_to_pdf(report: dict, output_path: str):
    pdf = build_pdf(report)
    pdf.save(output_path)

def submit_to_portal(report: dict, portal_url: str):
    return httpx.post(portal_url, json=report)


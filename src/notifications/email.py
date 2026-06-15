# Updated: 2026-06-15T16:56:48Z
class EmailChannel:
    def deliver(self, to: str, body: str) -> bool:
        response = sendgrid_client.send(to=to, subject='Notification', body=body)
        return response.status_code == 202


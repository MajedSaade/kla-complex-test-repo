# Updated: 2026-06-15T16:56:48Z
class NotificationService:
    def __init__(self, channels: dict):
        self.channels = channels

    def send(self, template: str, recipient: str, context: dict):
        rendered = render_template(template, context)
        return self.channels['email'].deliver(recipient, rendered)


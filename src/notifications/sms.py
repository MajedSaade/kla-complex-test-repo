# Updated: 2026-06-15T16:56:48Z
class SMSChannel:
    def deliver(self, phone: str, message: str) -> bool:
        return twilio_client.messages.create(to=phone, body=message)


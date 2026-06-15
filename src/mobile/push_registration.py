# Updated: 2026-06-15T16:56:48Z
@router.post('/devices/register')
async def register_device(device_token: str, platform: str):
    await save_device_token(current_user.id, device_token, platform)


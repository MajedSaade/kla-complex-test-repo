# Updated: 2026-06-15T16:56:48Z
from fastapi import APIRouter
router = APIRouter(prefix='/api/v1/mobile')

@router.get('/health')
def health(): return {'status': 'ok'}


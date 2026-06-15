# Updated: 2026-06-15T16:56:48Z
import logging
logger = logging.getLogger('payment.diagnostics')

def log_lock_state(queue):
    logger.debug('Lock held: %s', queue._lock.locked())


"""Push transport identifiers and expiry; never changes model/chat identifiers."""
import hashlib
import re


def request_id(job_id):
    if re.fullmatch(r'[a-zA-Z0-9:_-]{1,128}', job_id):
        return job_id
    return 'wake-' + hashlib.sha256(job_id.encode('utf-8')).hexdigest()


class HTTPFailure(RuntimeError):
    def __init__(self, path, status):
        self.status = int(status) if str(status).isdigit() else None
        super().__init__('HTTP ' + path.split('?')[0] + ' failed (' + str(status or 'network') + ')')

    @property
    def permanent(self):
        return self.status is not None and 400 <= self.status < 500 and self.status not in (408, 429)


def expired_dream(job, now):
    # A greeting is already in chat. A much later push must not replay old mornings.
    return (job.get('source') == 'morning-dream' and job.get('status') == 'saved'
            and bool(job.get('finished')) and now - job['finished'] >= 30 * 60)

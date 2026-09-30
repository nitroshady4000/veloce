"""Protocol errors shared by the dictation and meeting engines."""


class EngineError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code

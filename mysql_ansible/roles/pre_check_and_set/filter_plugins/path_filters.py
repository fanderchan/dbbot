from ansible.errors import AnsibleFilterError
from os.path import dirname

def parent_dirs(path):
    if not isinstance(path, str):
        raise AnsibleFilterError("parent_dirs filter: path must be a string")

    dirs = []
    while path != "/":
        path = dirname(path)
        dirs.append(path)

    return dirs

class FilterModule(object):
    def filters(self):
        return {
            'parent_dirs': parent_dirs
        }


"""Make bundled Mach-O dependencies independent of a guest executable's path."""
import os
import struct
import subprocess
from pathlib import Path

DYLIB_LOADS = {0xc, 0x18 | 0x80000000, 0x1f | 0x80000000, 0x23 | 0x80000000, 0x20}


def dependencies(data):
    if data[:4] != b'\xcf\xfa\xed\xfe':
        if data[:4] in {b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe'}:
            raise ValueError('Expected a thin 64-bit Mach-O image')
        return None
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data):
        raise ValueError('Truncated Mach-O commands')
    offset, result = 32, []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > end:
            raise ValueError('Invalid load command length')
        if command in DYLIB_LOADS:
            if length < 24:
                raise ValueError('Truncated dylib command')
            start = struct.unpack_from('<I', data, offset + 8)[0]
            if start < 24 or start >= length:
                raise ValueError('Invalid dylib name offset')
            name = data[offset + start:offset + length].split(b'\0', 1)[0].decode()
            result.append(name)
        offset += length
    return result


def images(app):
    return [(p, deps) for p in sorted(app.rglob('*')) if p.is_file()
            and (deps := dependencies(p.read_bytes())) is not None]


def bundled_target(app, image, dependency):
    if dependency.startswith('@rpath/'):
        target = app / 'Frameworks' / dependency[len('@rpath/'):]
        if target.is_file():
            return target
        # These are supplied by the OS, rather than copied into the host.
        if dependency.startswith('@rpath/libswift'):
            return None
        raise ValueError(f'Missing bundled dependency: {image}: {dependency}')
    if dependency.startswith('@loader_path/'):
        target = (image.parent / dependency[len('@loader_path/'):]).resolve()
        if not target.is_relative_to(app.resolve()) or not target.is_file():
            raise ValueError(f'Invalid loader-relative dependency: {image}: {dependency}')
        return target
    if dependency.startswith(('/usr/lib/', '/System/Library/')):
        return None
    raise ValueError(f'Unsupported dependency: {image}: {dependency}')


def normalize(app):
    changed = []
    for image, deps in images(app):
        changes = []
        for dependency in deps:
            target = bundled_target(app, image, dependency)
            if target is None:
                continue
            desired = '@loader_path/' + os.path.relpath(target, image.parent)
            if dependency != desired:
                changes += ['-change', dependency, desired]
        if changes:
            subprocess.run(['install_name_tool', *changes, str(image)], check=True)
            changed.append(image)
    verify(app)
    return changed


def verify(app):
    edges = []
    for image, deps in images(app):
        for dependency in deps:
            target = bundled_target(app, image, dependency)
            if target is not None:
                if not dependency.startswith('@loader_path/'):
                    raise ValueError(f'Guest-dependent bundled library path: {image}: {dependency}')
                edges.append({'image': str(image.relative_to(app)), 'dependency': dependency})
    return edges

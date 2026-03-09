#!/usr/bin/env python
from __future__ import print_function

import argparse
import binascii
import glob
import grp
import os
import pwd
import re
import shutil
import struct
import subprocess
import sys
import time

DEBUG = False


def log(message):
    sys.stdout.write(message + "\n")
    sys.stdout.flush()


def debug(message):
    if DEBUG:
        log("debug: " + message)


def die(message, code=1):
    sys.stderr.write("ERROR: " + message + "\n")
    sys.stderr.flush()
    sys.exit(code)


def print_summary(title, items):
    log("== %s ==" % title)
    width = 0
    for key, _ in items:
        if len(key) > width:
            width = len(key)
    for key, value in items:
        log("  %-*s: %s" % (width, key, value))
    log("")


def resolve_backup_paths(backup_dir):
    backup_dir = backup_dir.rstrip("/")
    if not backup_dir:
        die("backup_dir is empty")
    meta_dir = os.path.join(backup_dir, "meta")
    clone_dir = os.path.join(backup_dir, "clone")
    base_dir = os.path.dirname(backup_dir)
    binlog_dir = os.path.join(base_dir, "binlog")
    snapshot_id = os.path.basename(backup_dir)
    meta_file = os.path.join(meta_dir, "%s.meta" % snapshot_id)
    if os.path.isfile(meta_file):
        return meta_file, clone_dir, binlog_dir
    meta_candidates = glob.glob(os.path.join(meta_dir, "*.meta"))
    if len(meta_candidates) == 1:
        return meta_candidates[0], clone_dir, binlog_dir
    if not meta_candidates:
        die("meta file not found in %s" % meta_dir)
    die("multiple meta files found in %s: %s" % (meta_dir, ", ".join(meta_candidates)))


def read_binlog_index(path):
    entries = []
    try:
        handle = open(path, "r")
    except IOError as exc:
        die("failed to open binlog index %s: %s" % (path, exc))
    for raw in handle:
        line = raw.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        entries.append((parts[0], parts[1]))
    handle.close()
    entries.sort(key=lambda item: item[0])
    return entries


def build_binlog_list(base_dir, binlog_dir, start_file):
    index_path = os.path.join(base_dir, "binlog.txt")
    if not os.path.isfile(index_path):
        return [], "", False
    entries = read_binlog_index(index_path)
    files = []
    found_start = False
    for binlog_file, snapshot_id in entries:
        if binlog_file == start_file:
            found_start = True
        if binlog_file < start_file:
            continue
        path = os.path.join(binlog_dir, binlog_file)
        files.append(path)
    return files, index_path, found_start


def read_kv_file(path):
    data = {}
    try:
        handle = open(path, "r")
    except IOError as exc:
        die("failed to open file %s: %s" % (path, exc))
    for raw in handle:
        line = raw.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    handle.close()
    return data


def parse_meta(path):
    data = read_kv_file(path)
    mysql_version = data.get("mysql_version", "")
    match = re.match(r"^([0-9]+\.[0-9]+\.[0-9]+)", mysql_version)
    data["mysql_version_short"] = match.group(1) if match else ""
    gtid = data.get("gtid_executed", "")
    gtid = gtid.replace("\\n", "").replace("\\r", "")
    data["gtid_executed"] = re.sub(r"\s+", "", gtid)
    return data


def parse_mycnf(path):
    data = {}
    try:
        handle = open(path, "r")
    except IOError as exc:
        die("failed to open my.cnf %s: %s" % (path, exc))
    for raw in handle:
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        value = re.split(r"\s[;#]", value, 1)[0].strip()
        data[key] = value
    handle.close()
    return data


def get_mycnf_value(conf, *keys):
    for key in keys:
        value = conf.get(key, "")
        if value:
            return value
    return ""


def normalize_path(value, datadir):
    if not value or value in (".", "./"):
        return datadir
    if value.startswith("./"):
        return os.path.join(datadir, value[2:])
    return value


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def chown_recursive(path, user, group):
    try:
        uid = pwd.getpwnam(user).pw_uid
    except KeyError:
        die("mysql user not found: %s" % user)
    try:
        gid = grp.getgrnam(group).gr_gid
    except KeyError:
        die("mysql group not found: %s" % group)
    for root, dirs, files in os.walk(path):
        try:
            os.chown(root, uid, gid)
        except OSError:
            pass
        for name in dirs:
            target = os.path.join(root, name)
            try:
                os.chown(target, uid, gid)
            except OSError:
                pass
        for name in files:
            target = os.path.join(root, name)
            try:
                os.chown(target, uid, gid)
            except OSError:
                pass


def clear_datadir(datadir):
    if datadir in ("", "/") or len(datadir) <= 1:
        die("refusing to clear unsafe datadir: %s" % datadir)
    if not os.path.isdir(datadir):
        return
    for name in os.listdir(datadir):
        target = os.path.join(datadir, name)
        try:
            if os.path.islink(target) or os.path.isfile(target):
                os.unlink(target)
            else:
                shutil.rmtree(target)
        except OSError as exc:
            die("failed to remove %s: %s" % (target, exc))


def run_cmd(cmd, env=None):
    log("run: %s" % " ".join(cmd))
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        die("failed to run %s: %s" % (cmd[0], exc))
    out, err = proc.communicate()
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        die("command failed: %s" % " ".join(cmd))
    return out


def to_bytes(value):
    if isinstance(value, bytes):
        return value
    return value.encode("utf-8")


def mysql_base_cmd(args):
    return [
        args.mysql_bin,
        "--user=%s" % args.mysql_user,
        "--host=%s" % args.mysql_host,
        "--port=%s" % args.mysql_port,
        "--protocol=TCP",
    ]


def mysql_env(args):
    env = os.environ.copy()
    if args.mysql_password:
        env["MYSQL_PWD"] = args.mysql_password
    elif os.environ.get("MYSQL_PWD"):
        env["MYSQL_PWD"] = os.environ.get("MYSQL_PWD")
    else:
        die("mysql password not provided (use --mysql-password or MYSQL_PWD)")
    return env


def mysql_query(args, sql, env):
    debug("query: %s" % sql)
    cmd = mysql_base_cmd(args) + ["-Nse", sql]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        die("failed to run mysql query: %s" % exc)
    start = time.time()
    out, err = proc.communicate()
    if DEBUG:
        debug("query done (rc=%s, elapsed=%.3fs)" % (proc.returncode, time.time() - start))
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        die("mysql query failed")
    if hasattr(out, "decode"):
        out = out.decode("utf-8", "ignore")
    out = out.strip()
    if DEBUG:
        debug("query result: %s" % out)
    return out


def mysql_query_allow_error(args, sql, env, warn_title="mysql query failed but ignored"):
    debug("query(allow_error): %s" % sql)
    cmd = mysql_base_cmd(args) + ["-Nse", sql]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        log("warning: %s (%s)" % (warn_title, exc))
        return ""
    out, err = proc.communicate()
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        log("warning: %s (exit=%s)" % (warn_title, proc.returncode))
        return ""
    if hasattr(out, "decode"):
        out = out.decode("utf-8", "ignore")
    return out.strip()


def mysql_query_status(args, sql, env):
    debug("query(status): %s" % sql)
    cmd = mysql_base_cmd(args) + ["-Nse", sql]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        return 1, "", str(exc)
    out, err = proc.communicate()
    if proc.returncode != 0:
        err_text = err.decode("utf-8", "ignore") if hasattr(err, "decode") else err
        return proc.returncode, "", err_text
    if hasattr(out, "decode"):
        out = out.decode("utf-8", "ignore")
    return 0, out.strip(), ""


def mysql_exec(args, sql, env):
    debug("sql: %s" % sanitize_sql(sql))
    cmd = mysql_base_cmd(args)
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        die("failed to run mysql command: %s" % exc)
    start = time.time()
    out, err = proc.communicate(to_bytes(sql))
    if DEBUG:
        debug("sql done (rc=%s, elapsed=%.3fs)" % (proc.returncode, time.time() - start))
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        die("mysql command failed")
    return out


def sanitize_sql(sql):
    masked = re.sub(r"(SOURCE_PASSWORD=')([^']*)(')", r"\1***\3", sql)
    masked = re.sub(r"(PASSWORD=')([^']*)(')", r"\1***\3", masked)
    return masked


def mysql_exec_allow_error(args, sql, env, warn_title="mysql command failed but ignored"):
    # Step 1 allows errors and continues
    debug("sql(allow_error): %s" % sanitize_sql(sql))
    cmd = mysql_base_cmd(args)
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        die("failed to run mysql command: %s" % exc)
    start = time.time()
    out, err = proc.communicate(to_bytes(sql))
    if DEBUG:
        debug("sql(allow_error) done (rc=%s, elapsed=%.3fs)" % (proc.returncode, time.time() - start))
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        log("warning: %s (exit=%s)" % (warn_title, proc.returncode))
    return out


def mysql_show_replica_status(args, env):
    cmd = mysql_base_cmd(args) + ["-e", "SHOW REPLICA STATUS\\G"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as exc:
        die("failed to run mysql show replica status: %s" % exc)
    out, err = proc.communicate()
    if proc.returncode != 0:
        sys.stderr.write(err.decode("utf-8", "ignore") if hasattr(err, "decode") else err)
        sys.stderr.flush()
        die("mysql show replica status failed")
    if hasattr(out, "decode"):
        out = out.decode("utf-8", "ignore")
    return out


def parse_show_replica_status(output):
    data = {}
    for raw in output.splitlines():
        line = raw.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip()
    return data


def debug_dump_query(args, env, title, sql):
    log("debug: %s" % title)
    output = mysql_query_allow_error(args, sql, env, warn_title="%s failed but ignored" % title)
    if output:
        for line in output.splitlines():
            log("debug:   %s" % line)
    else:
        log("debug:   (empty)")


def debug_replication_state(args, env, title, raw_status=None):
    log("debug: %s" % title)
    if raw_status is not None:
        if raw_status.strip():
            log("debug: SHOW REPLICA STATUS raw:")
            for line in raw_status.splitlines():
                log("debug:   %s" % line)
        else:
            log("debug: SHOW REPLICA STATUS raw: (empty)")
    debug_dump_query(
        args,
        env,
        "replication_connection_status",
        "select CHANNEL_NAME, SERVICE_STATE, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, "
        "SOURCE_HOST, SOURCE_PORT from performance_schema.replication_connection_status",
    )
    debug_dump_query(
        args,
        env,
        "replication_applier_status",
        "select CHANNEL_NAME, SERVICE_STATE, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE "
        "from performance_schema.replication_applier_status",
    )
    debug_dump_query(
        args,
        env,
        "replication_applier_status_by_worker (limit 5)",
        "select CHANNEL_NAME, WORKER_ID, SERVICE_STATE, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE "
        "from performance_schema.replication_applier_status_by_worker limit 5",
    )
    debug_dump_query(args, env, "variables gtid_mode", "select @@global.gtid_mode")
    debug_dump_query(args, env, "variables relay_log", "show variables like 'relay_log%'")
    debug_dump_query(args, env, "variables log_bin", "show variables like 'log_bin%'")


def replica_thread_rows(args, env):
    sql = (
        "select NAME, PROCESSLIST_STATE from performance_schema.threads "
        "where NAME like 'thread/sql/replica_%' or NAME like 'thread/sql/slave_%'"
    )
    rc, out, err = mysql_query_status(args, sql, env)
    if rc != 0:
        log("warning: replica thread query failed (rc=%s): %s" % (rc, err))
        return None
    if not out:
        return []
    return out.splitlines()


def gtid_subset_reached(args, env, target_gtid):
    if not target_gtid:
        return False
    sql = "select GTID_SUBSET('%s', @@global.gtid_executed)" % sql_escape(target_gtid)
    rc, out, err = mysql_query_status(args, sql, env)
    if rc != 0:
        log("warning: gtid_subset check failed (rc=%s): %s" % (rc, err))
        return False
    return out.strip() == "1"


def copy_clone(clone_dir, datadir):
    if not os.path.isdir(clone_dir):
        die("clone backup directory not found: %s" % clone_dir)
    if not os.path.isdir(datadir):
        os.makedirs(datadir)
    run_cmd(["/bin/cp", "-a", os.path.join(clone_dir, "."), datadir])


def move_path(src, dest):
    if not os.path.exists(src):
        return
    if os.path.exists(dest):
        return
    try:
        shutil.move(src, dest)
    except OSError as exc:
        die("failed to move %s to %s: %s" % (src, dest, exc))


def move_redo_undo(datadir, redo_dir, undo_dir):
    if redo_dir != datadir:
        ensure_dir(redo_dir)
        move_path(os.path.join(datadir, "#innodb_redo"), os.path.join(redo_dir, "#innodb_redo"))
        for entry in glob.glob(os.path.join(datadir, "ib_logfile*")):
            move_path(entry, os.path.join(redo_dir, os.path.basename(entry)))
    if undo_dir != datadir:
        ensure_dir(undo_dir)
        move_path(os.path.join(datadir, "#innodb_undo"), os.path.join(undo_dir, "#innodb_undo"))
        for entry in glob.glob(os.path.join(datadir, "undo*")):
            move_path(entry, os.path.join(undo_dir, os.path.basename(entry)))


def list_binlogs(binlog_dir):
    if not os.path.isdir(binlog_dir):
        die("binlog backup directory not found: %s" % binlog_dir)
    files = []
    for entry in os.listdir(binlog_dir):
        path = os.path.join(binlog_dir, entry)
        if os.path.isfile(path):
            files.append(path)
    files.sort(key=lambda p: os.path.basename(p))
    return files


def sql_escape(value):
    return value.replace("\\", "\\\\").replace("'", "''")


def resolve_relay_paths(args, env, mycnf=None):
    row = mysql_query(args, "select @@global.datadir, @@global.relay_log_index, @@global.relay_log", env)
    parts = row.split("\t")
    datadir = parts[0].strip().rstrip("/")
    relay_index = parts[1].strip() if len(parts) > 1 else ""
    relay_log = parts[2].strip() if len(parts) > 2 else ""
    if mycnf:
        cfg_datadir = get_mycnf_value(mycnf, "datadir")
        cfg_relay_log = get_mycnf_value(mycnf, "relay_log", "relay-log")
        cfg_relay_index = get_mycnf_value(mycnf, "relay_log_index", "relay-log-index")
        if cfg_datadir:
            datadir = cfg_datadir.strip().rstrip("/")
        if cfg_relay_log:
            relay_log = cfg_relay_log.strip()
        if cfg_relay_index:
            relay_index = cfg_relay_index.strip()
    if not datadir:
        die("failed to resolve datadir from MySQL")
    if not relay_index:
        if relay_log:
            relay_index = relay_log + ".index" if not relay_log.endswith(".index") else relay_log
        else:
            relay_index = "relay-bin.index"
    if not relay_log:
        if relay_index.endswith(".index"):
            relay_log = relay_index[: -len(".index")]
        else:
            relay_log = relay_index
    if not os.path.isabs(relay_log):
        relay_log = os.path.join(datadir, relay_log)
    if not os.path.isabs(relay_index):
        relay_index = os.path.join(datadir, relay_index)
    relay_dir = os.path.dirname(relay_log)
    relay_prefix = os.path.basename(relay_log)
    return datadir, relay_dir, relay_index, relay_prefix


def resolve_owner(path):
    try:
        stat_info = os.stat(path)
    except OSError as exc:
        die("failed to stat %s: %s" % (path, exc))
    return stat_info.st_uid, stat_info.st_gid


def read_first_nonempty_line(path):
    if not os.path.isfile(path):
        if DEBUG:
            debug("index not found: %s" % path)
        return ""
    try:
        handle = open(path, "r")
    except IOError:
        return ""
    for raw in handle:
        line = raw.strip()
        if line:
            handle.close()
            if DEBUG:
                debug("index first line: %s" % line)
            return line
    handle.close()
    if DEBUG:
        debug("index file empty: %s" % path)
    return ""


def read_nonempty_lines(path):
    if not os.path.isfile(path):
        if DEBUG:
            debug("index not found: %s" % path)
        return []
    try:
        handle = open(path, "r")
    except IOError:
        return []
    lines = []
    for raw in handle:
        line = raw.strip()
        if line:
            lines.append(line)
    handle.close()
    if DEBUG:
        debug("index lines: %d" % len(lines))
    return lines


def clear_relay_files_except(relay_dir, prefix_base, keep_names):
    if not os.path.isdir(relay_dir):
        return
    keep = set(keep_names or [])
    removed = []
    for name in os.listdir(relay_dir):
        if not name.startswith(prefix_base + "."):
            continue
        if name in keep:
            continue
        try:
            os.unlink(os.path.join(relay_dir, name))
            removed.append(name)
        except OSError:
            pass
    if DEBUG:
        if removed:
            sample = ", ".join(removed[:10])
            more = " (+%d more)" % (len(removed) - 10) if len(removed) > 10 else ""
            debug("removed relay files: %s%s" % (sample, more))
        else:
            debug("no relay files removed (prefix=%s)" % prefix_base)


def write_lines_atomic(path, lines, uid=None, gid=None):
    tmp_path = path + ".pitr"
    if DEBUG:
        debug("write_lines_atomic: %s (count=%d)" % (path, len(lines)))
        if lines:
            debug("write_lines_atomic: first=%s" % lines[0])
            if len(lines) > 1:
                debug("write_lines_atomic: last=%s" % lines[-1])
    try:
        handle = open(tmp_path, "w")
    except IOError as exc:
        die("failed to write file %s: %s" % (tmp_path, exc))
    for line in lines:
        handle.write(line + "\n")
    handle.close()
    try:
        os.rename(tmp_path, path)
    except OSError as exc:
        die("failed to move file into place %s: %s" % (path, exc))
    if uid is not None and gid is not None:
        try:
            os.chown(path, uid, gid)
        except OSError:
            pass


def format_uuid(raw_bytes):
    hex_value = binascii.hexlify(raw_bytes)
    if not isinstance(hex_value, str):
        hex_value = hex_value.decode("ascii")
    return "%s-%s-%s-%s-%s" % (
        hex_value[0:8],
        hex_value[8:12],
        hex_value[12:16],
        hex_value[16:20],
        hex_value[20:32],
    )


def parse_time_string(value):
    try:
        return int(time.mktime(time.strptime(value, "%Y-%m-%d %H:%M:%S")))
    except ValueError:
        die("invalid time format: %s (expected YYYY-MM-DD HH:MM:SS)" % value)


def scan_binlog_for_gtid(path, target_ts):
    last_gtid = ""
    exceeded = False
    gtid_found = False
    first_ts = None
    last_ts = None
    debug("scan binlog: %s" % path)
    try:
        handle = open(path, "rb")
    except IOError as exc:
        die("failed to open binlog %s: %s" % (path, exc))
    magic = handle.read(4)
    if magic != b"\xfe\x62\x69\x6e":
        handle.close()
        die("invalid binlog magic header in %s" % path)
    while True:
        header = handle.read(19)
        if not header:
            break
        if len(header) < 19:
            break
        try:
            timestamp, event_type, _, event_size, _, _ = struct.unpack("<IBIIIH", header)
        except struct.error:
            break
        if first_ts is None:
            first_ts = timestamp
        last_ts = timestamp
        if event_size < 19:
            handle.close()
            die("invalid event size in %s" % path)
        data = handle.read(event_size - 19)
        if timestamp > target_ts and last_gtid:
            exceeded = True
            break
        if event_type == 33 and len(data) >= 25:
            gtid_found = True
            sid = data[1:17]
            gno = struct.unpack("<Q", data[17:25])[0]
            gtid = "%s:%d" % (format_uuid(sid), gno)
            if timestamp <= target_ts:
                last_gtid = gtid
            else:
                if last_gtid:
                    exceeded = True
                break
    handle.close()
    return last_gtid, exceeded, gtid_found, first_ts, last_ts


def format_ts(value):
    if value is None:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(value))


def find_gtid_by_time(binlog_files, target_time):
    target_ts = parse_time_string(target_time)
    last_gtid = ""
    gtid_seen = False
    first_ts = None
    last_ts = None
    for path in binlog_files:
        gtid, exceeded, gtid_found, first_seen, last_seen = scan_binlog_for_gtid(path, target_ts)
        if gtid_found:
            gtid_seen = True
        if first_seen is not None and (first_ts is None or first_seen < first_ts):
            first_ts = first_seen
        if last_seen is not None:
            last_ts = last_seen
        if gtid:
            last_gtid = gtid
        if exceeded and last_gtid:
            break
    return last_gtid, gtid_seen, first_ts, last_ts


def validate_gtid_set(value):
    # Supports uuid:seq and uuid:1-2115 GTID set formats (for SQL_AFTER_GTIDS).
    if not value:
        die("invalid target GTID: empty")
    value = re.sub(r"\s+", "", value)
    parts = value.split(",")
    for part in parts:
        if not part or ":" not in part:
            die("invalid GTID set part: %s" % part)
        uuid, intervals_str = part.split(":", 1)
        if not re.match(r"^[0-9a-fA-F-]{32,36}$", uuid):
            die("invalid GTID UUID: %s" % uuid)
        intervals = intervals_str.split(":")
        for interval in intervals:
            m = re.match(r"^([0-9]+)(-([0-9]+))?$", interval)
            if not m:
                die("invalid GTID interval: %s" % interval)
            if m.group(3) and int(m.group(1)) > int(m.group(3)):
                die("invalid GTID interval (start>end): %s" % interval)
    return value


def wait_sql_thread_stop(args, env, timeout, target_gtid=None):
    start = time.time()
    while time.time() - start < timeout:
        output = mysql_show_replica_status(args, env)
        status = parse_show_replica_status(output)
        if not status:
            if DEBUG:
                debug_replication_state(args, env, "replica status missing", raw_status=output)
            threads = replica_thread_rows(args, env)
            if threads is not None:
                if not threads:
                    return
                if DEBUG:
                    for line in threads[:5]:
                        log("debug: replica thread: %s" % line)
                    if len(threads) > 5:
                        log("debug: replica thread: ... (%d total)" % len(threads))
                time.sleep(2)
                continue
            if target_gtid and gtid_subset_reached(args, env, target_gtid):
                return
            time.sleep(2)
            continue
        err_no = status.get("Last_SQL_Errno") or status.get("Last_Error_Number") or "0"
        err_msg = status.get("Last_SQL_Error") or status.get("Last_Error_Message") or ""
        if err_no and err_no != "0":
            die("replication SQL error %s: %s" % (err_no, err_msg))
        sql_running = status.get("Replica_SQL_Running") or status.get("Slave_SQL_Running") or ""
        if DEBUG:
            relay_file = status.get("Relay_Log_File") or status.get("Relay_Master_Log_File") or ""
            relay_pos = status.get("Relay_Log_Pos") or status.get("Relay_Master_Log_Pos") or ""
            relay_space = status.get("Relay_Log_Space") or ""
            debug(
                "replica status: SQL=%s errno=%s relay=%s:%s space=%s"
                % (sql_running, err_no, relay_file, relay_pos, relay_space)
            )
        if sql_running and sql_running.lower() in ("no", "off", "false"):
            return
        time.sleep(2)
    die("timeout waiting for SQL thread to stop")


def apply_pitr(meta, args):
    # Relay-log replay flow (manual black-magic steps):
    # 2) RESET REPLICA ALL; CHANGE REPLICATION SOURCE TO RELAY_LOG_FILE='relay-bin.000001', RELAY_LOG_POS=4;
    # 3) RESET REPLICA;
    # 4) Append mysql-bin.* to relay-bin.index (relative paths)
    # 5) Copy mysql-bin.* into relay log dir
    # 6) CHANGE REPLICATION SOURCE TO RELAY_LOG_FILE='relay-bin.000001', RELAY_LOG_POS=4;
    # 7) START REPLICA SQL_THREAD UNTIL SQL_AFTER_GTIDS='...'
    # 9) RESET REPLICA ALL;
    binlog_file = meta.get("binlog_file", "")
    if not binlog_file:
        die("binlog_file missing in meta, cannot apply PITR")

    base_dir = os.path.dirname(args.backup_dir.rstrip("/"))
    binlog_dir = os.path.join(base_dir, "binlog")

    files, index_path, found_start = build_binlog_list(base_dir, binlog_dir, binlog_file)
    source = "binlog.txt"
    if index_path and not found_start:
        die("binlog.txt does not contain start binlog file %s" % binlog_file)
    if not files:
        files = list_binlogs(binlog_dir)
        index_path = binlog_dir
        source = "binlog_dir"

    start_base = os.path.basename(binlog_file)
    selected = [f for f in files if os.path.basename(f) >= start_base]
    if not selected:
        die("no binlog files found from %s in %s" % (binlog_file, index_path))

    missing = [path for path in selected if not os.path.isfile(path)]
    if missing:
        die("missing binlog files: %s" % ", ".join(missing[:5]))

    binlog_first = os.path.basename(selected[0])
    binlog_last = os.path.basename(selected[-1])
    log("scan binlogs: %s -> %s (count=%d)" % (binlog_first, binlog_last, len(selected)))

    if DEBUG:
        log("debug: selected binlogs:")
        for path in selected:
            log("debug:   %s" % os.path.basename(path))

    if args.pitr_target_time and args.pitr_target_gtid:
        die("set only one of --pitr-target-time or --pitr-target-gtid")
    if not args.pitr_target_time and not args.pitr_target_gtid:
        die("set one of --pitr-target-time or --pitr-target-gtid")

    target_mode = "gtid"
    target_gtid = args.pitr_target_gtid

    if args.pitr_target_time:
        target_mode = "time"
        last_gtid, gtid_seen, first_ts, last_ts = find_gtid_by_time(selected, args.pitr_target_time)
        if not last_gtid:
            log(
                "no GTID found before target time %s; "
                "binlog range %s -> %s; event range %s ~ %s; skip PITR"
                % (args.pitr_target_time, binlog_first, binlog_last, format_ts(first_ts), format_ts(last_ts))
            )
            if not gtid_seen:
                log("no GTID events detected in binlogs; verify GTID mode or binlog inputs")
            return

        # Common case is uuid:1-xxxx; convert uuid:seq to uuid:1-seq (single GTID).
        m = re.match(r"^([0-9a-fA-F-]+):([0-9]+)$", last_gtid)
        if m:
            target_gtid = "%s:1-%s" % (m.group(1), m.group(2))
        else:
            target_gtid = last_gtid

    target_gtid = validate_gtid_set(target_gtid)

    env = mysql_env(args)
    if not args.mysql_password:
        args.mysql_password = env.get("MYSQL_PWD", "")
    if not args.mysql_password:
        die("mysql password not provided for replication")

    mycnf = None
    if args.mycnf_file:
        mycnf = parse_mycnf(args.mycnf_file)
        if DEBUG:
            debug(
                "my.cnf: datadir=%s relay_log=%s relay_log_index=%s"
                % (
                    get_mycnf_value(mycnf, "datadir") or "-",
                    get_mycnf_value(mycnf, "relay_log", "relay-log") or "-",
                    get_mycnf_value(mycnf, "relay_log_index", "relay-log-index") or "-",
                )
            )

    datadir, relay_dir_guess, relay_index_path, relay_prefix_guess = resolve_relay_paths(args, env, mycnf)
    uid, gid = resolve_owner(datadir)

    if not relay_prefix_guess:
        relay_prefix_guess = "relay-bin"
    seed_file = "%s.000001" % relay_prefix_guess
    relay_dir = os.path.dirname(relay_index_path) or relay_dir_guess or datadir
    if not relay_dir:
        die("failed to resolve relay log directory")
    if DEBUG:
        debug(
            "relay resolved: datadir=%s relay_dir=%s relay_index=%s relay_prefix=%s"
            % (datadir, relay_dir, relay_index_path, relay_prefix_guess)
        )
        debug("seed relay file: %s" % seed_file)

    print_summary(
        "pitr_black_magic",
        [
            ("backup_dir", args.backup_dir),
            ("meta_file", args.meta_file),
            ("binlog_source", source),
            ("binlog_index", index_path),
            ("binlog_file", binlog_file),
            ("binlog_first", binlog_first),
            ("binlog_last", binlog_last),
            ("binlog_count", len(selected)),
            ("target_mode", target_mode),
            ("target_time", args.pitr_target_time or "-"),
            ("target_gtid", target_gtid),
            ("mycnf_file", args.mycnf_file or "-"),
            ("relay_log_index", relay_index_path),
            ("relay_log_dir", relay_dir),
            ("seed_relay_file", seed_file),
            ("fixed_relay_pos", "4"),
            ("self_host", args.mysql_host),
            ("self_port", args.mysql_port),
            ("self_user", args.mysql_user),
        ],
    )
    seed_change_sql = (
        "CHANGE REPLICATION SOURCE TO "
        "RELAY_LOG_FILE='%s', "
        "RELAY_LOG_POS=4"
        % (sql_escape(seed_file),)
    )

    # 2) RESET REPLICA ALL; seed CHANGE REPLICATION
    log("step2: RESET REPLICA ALL + seed CHANGE REPLICATION")
    mysql_exec(args, "RESET REPLICA ALL;", env)
    mysql_exec(args, seed_change_sql + ";", env)

    # 3) RESET REPLICA
    log("step3: RESET REPLICA")
    mysql_exec(args, "RESET REPLICA;", env)

    # 4) Append mysql-bin.* into relay-bin.index (relative paths)
    log("step4: append binlogs to relay index (relative paths)")
    ensure_dir(relay_dir)
    index_lines = read_nonempty_lines(relay_index_path)
    if not index_lines:
        seed_line = "./%s" % seed_file
        seed_path = os.path.join(relay_dir, seed_file)
        try:
            handle = open(seed_path, "ab")
            handle.close()
        except IOError as exc:
            die("failed to create seed relay file %s: %s" % (seed_path, exc))
        try:
            os.chown(seed_path, uid, gid)
        except OSError:
            pass
        write_lines_atomic(relay_index_path, [seed_line], uid, gid)
        index_lines = [seed_line]

    existing_names = set(os.path.basename(line) for line in index_lines)
    new_lines = []
    for src in selected:
        base = os.path.basename(src)
        if base in existing_names:
            continue
        new_lines.append("./%s" % base)
        existing_names.add(base)
    if new_lines:
        write_lines_atomic(relay_index_path, index_lines + new_lines, uid, gid)
        log("relay index updated: +%d entries" % len(new_lines))
    else:
        log("relay index updated: no new entries")
    if DEBUG:
        lines = read_nonempty_lines(relay_index_path)
        preview = lines[:10]
        for line in preview:
            log("debug: relay index: %s" % line)
        if len(lines) > 10:
            log("debug: relay index: ... (%d total)" % len(lines))

    # 5) Copy mysql-bin.* files into relay log dir
    log("step5: copy binlog files into relay dir")
    for src in selected:
        base = os.path.basename(src)
        dest_path = os.path.join(relay_dir, base)
        if DEBUG:
            debug("copy: %s -> %s" % (src, dest_path))
        try:
            shutil.copy2(src, dest_path)
        except OSError as exc:
            die("failed to copy binlog %s to %s: %s" % (src, dest_path, exc))
        try:
            os.chown(dest_path, uid, gid)
        except OSError:
            pass

    # 6) CHANGE REPLICATION again (fixed relay start)
    log("step6: CHANGE REPLICATION to seed relay file (RELAY_LOG_POS=4)")
    mysql_exec(args, seed_change_sql + ";", env)
    if DEBUG:
        debug_replication_state(args, env, "after step6")

    # 7) START REPLICA SQL_THREAD UNTIL SQL_AFTER_GTIDS='...'
    log("step7: START REPLICA SQL_THREAD UNTIL SQL_AFTER_GTIDS")
    start_sql = "START REPLICA SQL_THREAD UNTIL SQL_AFTER_GTIDS='%s'" % sql_escape(target_gtid)
    mysql_exec(args, start_sql + ";", env)
    wait_sql_thread_stop(args, env, 3600, target_gtid=target_gtid)

    # 9) cleanup replication (RESET REPLICA ALL)
    log("step9: cleanup replication (RESET REPLICA ALL)")
    mysql_exec(args, "RESET REPLICA ALL;", env)

    log("PITR apply finished")


def restore_phase(args):
    meta_file, clone_dir, _ = resolve_backup_paths(args.backup_dir)
    meta = parse_meta(meta_file)
    if not meta.get("mysql_version_short"):
        die("mysql_version missing in meta file")
    if not meta.get("mysql_version_short").startswith("8.4."):
        die("mysql_version %s is not supported, only 8.4.x allowed" % meta.get("mysql_version_short"))
    conf = parse_mycnf(args.mycnf_file)
    cfg_datadir = conf.get("datadir", "").strip().strip('"').strip("'")
    if not cfg_datadir:
        die("datadir not found in my.cnf: %s" % args.mycnf_file)
    datadir = cfg_datadir.rstrip("/")
    redo_dir = normalize_path(conf.get("innodb_log_group_home_dir", ""), datadir)
    undo_dir = normalize_path(conf.get("innodb_undo_directory", ""), datadir)
    print_summary(
        "restore",
        [
            ("backup_dir", args.backup_dir),
            ("meta_file", meta_file),
            ("clone_dir", clone_dir),
            ("mysql_version", meta.get("mysql_version", "")),
            ("datadir", datadir),
            ("redo_dir", redo_dir),
            ("undo_dir", undo_dir),
            ("allow_nonempty_datadir", args.allow_nonempty_datadir),
        ],
    )
    if os.path.isdir(datadir):
        contents = os.listdir(datadir)
        if contents and not args.allow_nonempty_datadir:
            die("datadir is not empty: %s" % datadir)
        if contents and args.allow_nonempty_datadir:
            log("step: clear datadir")
            clear_datadir(datadir)
    log("step: copy clone")
    copy_clone(clone_dir, datadir)
    log("step: move redo/undo")
    move_redo_undo(datadir, redo_dir, undo_dir)
    log("step: chown files")
    chown_recursive(datadir, args.mysql_user, args.mysql_group)
    if redo_dir != datadir:
        chown_recursive(redo_dir, args.mysql_user, args.mysql_group)
    if undo_dir != datadir:
        chown_recursive(undo_dir, args.mysql_user, args.mysql_group)
    log("restore finished")


def build_parser():
    parser = argparse.ArgumentParser(description="restore_pitr_84 helper")
    subparsers = parser.add_subparsers(dest="phase")
    restore = subparsers.add_parser("restore")
    restore.add_argument("--backup-dir", required=True)
    restore.add_argument("--mycnf-file", required=True)
    restore.add_argument("--mysql-user", required=True)
    restore.add_argument("--mysql-group", required=True)
    restore.add_argument("--allow-nonempty-datadir", action="store_true")
    restore.add_argument("--debug", action="store_true")

    pitr = subparsers.add_parser("pitr")
    pitr.add_argument("--backup-dir", required=True)
    pitr.add_argument("--mycnf-file", default="")
    pitr.add_argument("--mysql-bin", required=True)
    pitr.add_argument("--mysql-user", required=True)
    pitr.add_argument("--mysql-password", default="")
    pitr.add_argument("--mysql-host", required=True)
    pitr.add_argument("--mysql-port", required=True)
    pitr.add_argument("--pitr-target-time", default="")
    pitr.add_argument("--pitr-target-gtid", default="")
    pitr.add_argument("--pitr-target-gtid-inclusive", action="store_true")  # Keep for compatibility; black-magic flow always uses SQL_AFTER_GTIDS.
    pitr.add_argument("--debug", action="store_true")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    global DEBUG
    DEBUG = bool(getattr(args, "debug", False))
    if args.phase == "restore":
        restore_phase(args)
        return
    if args.phase == "pitr":
        meta_file, _, _ = resolve_backup_paths(args.backup_dir)
        meta = parse_meta(meta_file)
        args.meta_file = meta_file
        apply_pitr(meta, args)
        return
    parser.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()

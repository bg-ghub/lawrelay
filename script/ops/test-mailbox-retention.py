#!/usr/bin/env python3
"""Offline safety tests for mailbox-retention.py.  Never contacts IMAP."""
import argparse, contextlib, importlib.util, io, json, os, sys, tempfile, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec=importlib.util.spec_from_file_location("retention",Path(__file__).with_name("mailbox-retention.py")); retention=importlib.util.module_from_spec(spec); sys.modules[spec.name]=retention; spec.loader.exec_module(retention)
NOW=datetime(2026,10,29,tzinfo=timezone.utc)

def msg(uid, mid, *, internal="01-Jan-2020 00:00:00 +0000", flags="", refs=None, reply=None, extra=""):
    h=[f"Message-ID: {mid}","Date: Wed, 01 Jan 2020 00:00:00 +0000"]
    if reply is not None: h.append(f"In-Reply-To: {reply}")
    if refs is not None: h.append(f"References: {refs}")
    raw=("\r\n".join(h)+"\r\n"+extra+"\r\n").encode()
    return (f'* {uid} FETCH (UID {uid} FLAGS ({flags}) INTERNALDATE "{internal}" BODY[HEADER.FIELDS] {{{len(raw)}}}'.encode(),raw)

def boxes(extra=None):
    b={"Support/Resolved":{"uv":"1","m":{"1":msg("1","<a@test>")}},"Sent":{"uv":"2","m":{"2":msg("2","<b@test>",refs="<a@test>")}},"Drafts":{"uv":"3","m":{}},"INBOX":{"uv":"4","m":{}}}
    if extra: extra(b)
    return b

class FakeIMAP:
    """Records every selection and UID mutation; supports race/failure injection."""
    def __init__(self,b,*,uidplus=True,fail_expunge=None,on_select=None):
        self.boxes,self.current,self.capabilities=b,None,((b"UIDPLUS",) if uidplus else ()); self.commands=[]; self.selects=[]; self.fail_expunge=fail_expunge; self.on_select=on_select
    def login(self,*_): return "OK",[b""]
    def logout(self): self.commands.append(("LOGOUT",)); return "BYE",[b""]
    def list(self,*args):
        if args and args[0] == "": return "NO", [b"empty reference is rejected by Migadu"]
        return "OK",[f'(\\HasNoChildren) "/" "{x}"'.encode() for x in self.boxes]
    def select(self,name,readonly=True):
        logical=name[1:-1].replace('\\\\','\\').replace('\\"','"') if name.startswith('"') and name.endswith('"') else name
        self.current=logical; self.selects.append((logical,readonly)); self.commands.append(("SELECT",logical,readonly))
        if self.on_select: self.on_select(self,logical,readonly)
        return "OK",[b"1"]
    def response(self,_): return b"UIDVALIDITY",[self.boxes[self.current]["uv"].encode()]
    def uid(self,command,*args):
        self.commands.append((command,self.current,*args)); box=self.boxes[self.current]
        if command=="SEARCH": return "OK",[" ".join(box["m"]).encode()]
        if command=="FETCH": return "OK",[box["m"].get(args[0],b"")]
        if command=="STORE": return "OK",[b""]
        if command=="EXPUNGE":
            if self.fail_expunge and self.fail_expunge(self.current,args[0]): return "NO",[b"no"]
            for uid in args[0].split(","): box["m"].pop(uid,None)
            return "OK",[b""]
        return "NO",[]
    def close(self): raise AssertionError("global CLOSE must never be used")

class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); os.chmod(self.tmp.name,0o700); self.root=Path(self.tmp.name)
        self.env=self.root/"env"; self.env.write_text("SMTP_USERNAME=admin@lawrelay.be\nSMTP_PASSWORD=secret-password\n"); os.chmod(self.env,0o600)
        self.state,self.marker=self.root/"state.json",self.root/"last-success"; self.protected,self.secure=retention.protected_regular,retention.State._secure_dir
        if os.name=="nt": retention.protected_regular=lambda p,**kw: None if kw.get("allow_missing") and not Path(p).exists() else Path(p).lstat(); retention.State._secure_dir=lambda _:None
    def tearDown(self): retention.protected_regular,retention.State._secure_dir=self.protected,self.secure; self.tmp.cleanup()
    def args(self,apply=False): return argparse.Namespace(env_file=str(self.env),state_file=str(self.state),success_file=str(self.marker),folder="Support/Resolved",sent_folder="Sent",timeout=1,apply=apply)
    def execute(self,clients,apply=False):
        i=iter(clients); return retention.run(self.args(apply),imap_factory=lambda *_:next(i),clock=lambda:NOW)
    def mature(self,data):
        self.execute([FakeIMAP(data),FakeIMAP(data)],True); s=retention.State(self.state)
        with s.locked():
            for e in s.value["folders"].values():
                for r in e["messages"].values(): r["first_seen"]=(NOW.replace(year=NOW.year-2)-timedelta(days=1)).isoformat()
            s.save()
        self.marker.unlink(missing_ok=True)

    def test_preview_no_writes_first_apply_zero_eligible_writes_state_and_marker(self):
        data=boxes(); self.assertEqual(self.execute([FakeIMAP(data)])["eligible"],0); self.assertFalse(self.state.exists()); self.assertFalse(self.marker.exists())
        self.assertEqual(self.execute([FakeIMAP(data),FakeIMAP(data)],True)["deleted"],0); self.assertTrue(self.state.exists()); self.assertTrue(self.marker.exists())

    def test_exact_uids_allowlisted_folders_no_global_expunge_or_close(self):
        def extra(b):
            b["Sent"]["m"]["8"]=msg("8","<other@test>"); b["Drafts"]["m"]["9"]=msg("9","<draft@test>"); b["Support/Resolved"]["m"]["7"]=msg("7","<deleted@test>",flags="\\Deleted")
        data=boxes(extra); self.mature(data); live=FakeIMAP(data); self.assertEqual(self.execute([FakeIMAP(data),live],True)["deleted"],2)
        muts=[x for x in live.commands if x[0] in {"STORE","EXPUNGE"}]
        self.assertTrue(muts); self.assertTrue(all(x[1] in {"Support/Resolved","Sent"} for x in muts)); self.assertTrue(all(x[0]!="EXPUNGE" or len(x)==3 and x[2] in {"1","2"} for x in muts))
        self.assertIn("7",data["Support/Resolved"]["m"]); self.assertIn("8",data["Sent"]["m"]); self.assertIn("9",data["Drafts"]["m"])

    def test_new_inbox_or_sent_reply_delays_old_thread(self):
        for folder in ("INBOX","Sent"):
            with self.subTest(folder=folder):
                data=boxes(lambda b,f=folder:b[f]["m"].update({"3":msg("3","<new@test>",internal="29-Oct-2026 00:00:00 +0000",refs="<a@test>")})); self.mature(data); self.assertEqual(self.execute([FakeIMAP(data)])["eligible"],0)

    def test_unselected_folder_with_spaces_is_scanned_and_protects_thread(self):
        def extra(b): b["Old Support"]={"uv":"5","m":{"6":msg("6","<outside@test>",refs="<a@test>")}}
        data=boxes(extra); self.mature(data); preview=FakeIMAP(data)
        self.assertEqual(self.execute([preview])["eligible"],0)
        self.assertIn(("Old Support",True),preview.selects)
        self.assertEqual(data["Old Support"]["m"].keys(),{"6"})

    def test_draft_missing_flags_duplicate_id_and_bad_reply_protect(self):
        cases=[
            lambda b:b["Support/Resolved"]["m"].update({"3":msg("3","<draft@test>",flags="\\Draft",refs="<a@test>")}),
            lambda b:b["Support/Resolved"]["m"].update({"1":(b'* 1 FETCH (UID 1 INTERNALDATE "01-Jan-2020 00:00:00 +0000)',b"Message-ID: <a@test>\r\nDate: Wed, 01 Jan 2020 00:00:00 +0000\r\n\r\n")}),
            lambda b:b["Support/Resolved"]["m"].update({"1":msg("1","<a@test>",extra="Message-ID: <other@test>\r\n")}),
            lambda b:b["INBOX"]["m"].update({"3":msg("3","<new@test>",reply="broken",refs="<a@test>")})]
        for add in cases:
            with self.subTest(add=add):
                data=boxes(add); self.mature(data); self.assertEqual(self.execute([FakeIMAP(data)])["eligible"],0)

    def test_mutation_time_flag_race_aborts_before_store(self):
        data=boxes(); self.mature(data); once={"v":False}
        def change(_,folder,readonly):
            if folder=="Support/Resolved" and not readonly and not once["v"]:
                data[folder]["m"]["1"]=msg("1","<a@test>",flags="\\Flagged"); once["v"]=True
        live=FakeIMAP(data,on_select=change)
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(data),live],True)
        self.assertFalse(any(x[0]=="STORE" for x in live.commands))

    def test_uidvalidity_change_at_writable_select_aborts_before_store(self):
        data=boxes(); self.mature(data); once={"v":False}
        def change(_,folder,readonly):
            if folder=="Support/Resolved" and not readonly and not once["v"]:
                data[folder]["uv"]="999"; once["v"]=True
        live=FakeIMAP(data,on_select=change)
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(data),live],True)
        self.assertFalse(any(x[0]=="STORE" for x in live.commands))

    def test_expunge_failure_rolls_back_only_this_uid_and_preserves_marker_state(self):
        data=boxes(); self.mature(data); self.marker.write_text("old\n"); before=self.state.read_bytes(); live=FakeIMAP(data,fail_expunge=lambda folder,_:folder=="Support/Resolved")
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(data),live],True)
        stores=[(x[1],x[2],x[3]) for x in live.commands if x[0]=="STORE"]
        self.assertEqual(stores,[("Support/Resolved","1","+FLAGS.SILENT"),("Support/Resolved","1","-FLAGS.SILENT")]); self.assertEqual(self.marker.read_text(),"old\n"); self.assertEqual(self.state.read_bytes(),before)

    def test_partial_cross_folder_failure_has_no_success_marker(self):
        data=boxes(); self.mature(data); self.marker.write_text("old\n"); live=FakeIMAP(data,fail_expunge=lambda folder,_:folder=="Sent")
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(data),live],True)
        self.assertEqual(self.marker.read_text(),"old\n"); self.assertTrue(any(x[:2]==("EXPUNGE","Support/Resolved") for x in live.commands)); self.assertTrue(any(x[:2]==("EXPUNGE","Sent") for x in live.commands))

    def test_no_uidplus_never_mutates(self):
        data=boxes(); self.mature(data); live=FakeIMAP(data,uidplus=False)
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(data,uidplus=False),live],True)
        self.assertFalse(any(x[0] in {"STORE","EXPUNGE"} for x in live.commands))

    def test_invalid_nested_state_and_feb29_cutoff(self):
        self.state.write_text(json.dumps({"version":1,"folders":{"Support/Resolved":{"uidvalidity":"1","messages":{"1":{"first_seen":"bad","extra":1}}}}}))
        with self.assertRaises(retention.SafetyError): self.execute([FakeIMAP(boxes())])
        s=retention.State(self.state); s.value={"version":1,"folders":{"Support/Resolved":{"uidvalidity":"1","messages":{"1":{"first_seen":"2022-02-27T00:00:00+00:00"}}}}}
        m=retention.Message("Support/Resolved","1",set(),datetime(2022,2,27,tzinfo=timezone.utc),datetime(2022,2,27,tzinfo=timezone.utc),"<a@test>",[],True)
        self.assertEqual(retention.eligible([m],"Support/Resolved","Sent",s,{"Support/Resolved":"1"},datetime(2024,2,29,tzinfo=timezone.utc))[0]["Support/Resolved"],["1"])

    @unittest.skipIf(os.name=="nt","POSIX ownership/link semantics")
    def test_unsafe_permissions_symlink_and_hardlink_reject(self):
        os.chmod(self.env,0o644)
        with self.assertRaises(retention.SafetyError): retention.read_env(self.env)
        os.chmod(self.env,0o600); link=self.root/"link"; link.symlink_to(self.env)
        with self.assertRaises(retention.SafetyError): retention.read_env(link)
        hard=self.root/"hard"; os.link(self.env,hard)
        with self.assertRaises(retention.SafetyError): retention.read_env(hard)

    def test_main_generic_error_hides_secret_and_subject(self):
        old,old_locks=retention.run,retention.POSIX_LOCKS; retention.POSIX_LOCKS=True; retention.run=lambda *_a,**_k:(_ for _ in ()).throw(RuntimeError("secret-password private subject")); out=io.StringIO()
        try:
            with contextlib.redirect_stderr(out): self.assertEqual(retention.main(["--env-file","x","--state-file","x","--folder","Support/Resolved"]),2)
        finally: retention.run,retention.POSIX_LOCKS=old,old_locks
        self.assertEqual(out.getvalue(),"mailbox retention: operational\n")

if __name__=="__main__": unittest.main()

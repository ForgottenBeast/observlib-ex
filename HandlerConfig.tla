---- MODULE HandlerConfig ----
(*
  Abstract model of the OTP logger handler config contract.

  Issue: ObservLib.Logs.Backend.Handler.adding_handler/1 strips the full
  OTP-supplied config to %{level: level}, discarding :module and other
  required fields.  OTP 28's logger:filter_config/1 pattern-matches on
  #{module:=Module}=Config and raises function_clause when :module is absent,
  causing VM shutdown to exit 1.

  This spec models the invariant that must hold: after a handler is
  registered, the stored config must contain all OTP-required fields.
  The fix (pass-through) satisfies this invariant; the broken version
  does not.
*)

EXTENDS TLC, FiniteSets

CONSTANTS
  RequiredFields,  \* Set of field names OTP requires in every stored config
  AllFields        \* Full set of fields OTP passes to adding_handler/1

ASSUME RequiredFields \subseteq AllFields
ASSUME RequiredFields # {}

\* Handler lifecycle states
States == {"unregistered", "registered", "shutdown"}

VARIABLES
  handler_state,   \* current lifecycle state
  stored_config    \* fields present in the stored handler config (subset of AllFields)

TypeOK ==
  /\ handler_state \in States
  /\ stored_config \subseteq AllFields

\* --- Model of adding_handler/1 implementations ---

\* Broken: strips all fields, keeps none of AllFields (or only non-required ones)
\* We model the broken variant as returning an empty set of fields.
BrokenAddingHandler(input_fields) == {}

\* Fixed: pass-through — returns all input fields unchanged
FixedAddingHandler(input_fields) == input_fields

\* Select which implementation to verify.
\* Switch to BrokenAddingHandler to confirm the spec detects the violation.
AddingHandler(input_fields) == FixedAddingHandler(input_fields)

\* --- State machine ---

Init ==
  /\ handler_state = "unregistered"
  /\ stored_config = {}

\* OTP calls adding_handler/1 with the full config (all fields present).
\* The returned value becomes the stored config.
Register ==
  /\ handler_state = "unregistered"
  /\ stored_config' = AddingHandler(AllFields)
  /\ handler_state' = "registered"

\* OTP calls filter_config/1 at shutdown (Logger.flush/0).
\* This action is only safe when RequiredFields are present in stored_config.
Shutdown ==
  /\ handler_state = "registered"
  /\ handler_state' = "shutdown"
  /\ UNCHANGED stored_config

\* Allow stuttering once shutdown is reached (terminal state).
Done == handler_state = "shutdown"

Stutter == Done /\ UNCHANGED <<handler_state, stored_config>>

Next == Register \/ Shutdown \/ Stutter

Spec == Init /\ [][Next]_<<handler_state, stored_config>>

\* --- Invariants ---

\* After registration, all OTP-required fields must be present in the stored config.
RequiredFieldsPreserved ==
  handler_state = "registered" => RequiredFields \subseteq stored_config

\* filter_config/1 is only called in the registered or shutdown states.
\* It must never see a stored config missing required fields.
FilterConfigSafe ==
  handler_state \in {"registered", "shutdown"} =>
    RequiredFields \subseteq stored_config

====

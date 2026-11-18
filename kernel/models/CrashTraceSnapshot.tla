--------------------- MODULE CrashTraceSnapshot ---------------------
\* One slot, two payload words, one writer and one bounded reader.
\* The writer either overwrites the slot or resets and reuses its sequence.
\* Word actions are interleavings; AArch64 ordering is checked separately.
EXTENDS Naturals
CONSTANTS
    \* @type: Bool;
    CHECK_COMMIT,
    \* @type: Bool;
    CHECK_GENERATION
VARIABLES
    \* @type: Int;
    writeStep,
    \* @type: Bool;
    reset,
    \* @type: Int;
    generation,
    \* @type: Int;
    commit,
    \* @type: Int;
    firstWord,
    \* @type: Int;
    secondWord,
    \* @type: Int;
    readStep,
    \* @type: Int;
    beforeGeneration,
    \* @type: Int;
    beforeCommit,
    \* @type: Int;
    gotFirst,
    \* @type: Int;
    gotSecond,
    \* @type: Bool;
    accepted

writer == <<writeStep, reset, generation, commit, firstWord, secondWord>>
reader == <<readStep, beforeGeneration, beforeCommit, gotFirst, gotSecond, accepted>>
vars == <<writer, reader>>

Init == /\ writeStep = 0 /\ reset = FALSE /\ generation = 0 /\ commit = 1
        /\ firstWord = 1 /\ secondWord = 1 /\ readStep = 0
        /\ beforeGeneration = 0 /\ beforeCommit = 0
        /\ gotFirst = 0 /\ gotSecond = 0 /\ accepted = FALSE

BeginReset == /\ writeStep = 0 /\ reset' = TRUE /\ generation' = 1
              /\ writeStep' = 1 /\ UNCHANGED <<commit, firstWord, secondWord, reader>>
Invalidate == /\ writeStep \in {0, 1}
              /\ commit' = 0 /\ writeStep' = 2
              /\ UNCHANGED <<reset, generation, firstWord, secondWord, reader>>
EndReset == /\ writeStep = 2 /\ reset /\ generation = 1 /\ generation' = 2
            /\ UNCHANGED <<writeStep, reset, commit, firstWord, secondWord, reader>>
WriteFirst == /\ writeStep = 2 /\ generation # 1
              /\ firstWord' = 2 /\ writeStep' = 3
              /\ UNCHANGED <<reset, generation, commit, secondWord, reader>>
WriteSecond == /\ writeStep = 3 /\ secondWord' = 2 /\ writeStep' = 4
               /\ UNCHANGED <<reset, generation, commit, firstWord, reader>>
Publish == /\ writeStep = 4 /\ commit' = IF reset THEN 1 ELSE 2
           /\ writeStep' = 5
           /\ UNCHANGED <<reset, generation, firstWord, secondWord, reader>>

ReadGeneration == /\ readStep = 0 /\ beforeGeneration' = generation /\ readStep' = 1
                  /\ UNCHANGED <<writer, beforeCommit, gotFirst, gotSecond, accepted>>
ReadCommit == /\ readStep = 1 /\ beforeCommit' = commit /\ readStep' = 2
              /\ UNCHANGED <<writer, beforeGeneration, gotFirst, gotSecond, accepted>>
ReadFirst == /\ readStep = 2 /\ gotFirst' = firstWord /\ readStep' = 3
             /\ UNCHANGED <<writer, beforeGeneration, beforeCommit, gotSecond, accepted>>
ReadSecond == /\ readStep = 3 /\ gotSecond' = secondWord /\ readStep' = 4
              /\ UNCHANGED <<writer, beforeGeneration, beforeCommit, gotFirst, accepted>>
RecheckCommit == /\ readStep = 4
                 /\ accepted' = (beforeCommit # 0 /\ (~CHECK_COMMIT \/ beforeCommit = commit))
                 /\ readStep' = 5
                 /\ UNCHANGED <<writer, beforeGeneration, beforeCommit, gotFirst, gotSecond>>
RecheckGeneration == /\ readStep = 5
                     /\ accepted' = (accepted /\ (~CHECK_GENERATION \/
                           (beforeGeneration # 1 /\ beforeGeneration = generation)))
                     /\ readStep' = 6
                     /\ UNCHANGED <<writer, beforeGeneration, beforeCommit, gotFirst, gotSecond>>
Done == /\ writeStep = 5 /\ readStep = 6 /\ UNCHANGED vars

Next == BeginReset \/ Invalidate \/ EndReset \/ WriteFirst \/ WriteSecond \/ Publish \/
        ReadGeneration \/ ReadCommit \/ ReadFirst \/ ReadSecond \/
        RecheckCommit \/ RecheckGeneration \/ Done
Spec == Init /\ [][Next]_vars

Coherent == (readStep = 6 /\ accepted) =>
    /\ gotFirst = gotSecond
    /\ gotFirst = (IF beforeCommit = 1 /\ beforeGeneration = 0 THEN 1 ELSE 2)
CInitFixed == CHECK_COMMIT = TRUE /\ CHECK_GENERATION = TRUE
CInitNoCommit == CHECK_COMMIT = FALSE /\ CHECK_GENERATION = TRUE
CInitNoGeneration == CHECK_COMMIT = TRUE /\ CHECK_GENERATION = FALSE
=============================================================================

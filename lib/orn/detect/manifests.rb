# frozen_string_literal: true

module Orn
  module Detect
    module Manifest
      # Detection manifests bundled with the gem, keyed by agent label. These
      # are the bundled agent-detection manifests as Ruby data
      # (regex strings copied verbatim). A user override in
      # `<global_config_dir>/agent-detection/<agent>.yaml` supersedes these.
      BUNDLED_MANIFESTS = {
        "claude" => {
          "id" => "claude",
          "aliases" => ["claude-code"],
          "rules" => [
            {
              "id" => "osc_title_working",

              "state" => "working",

              "priority" => 1100,
              "region" => "osc_title",

              "visible_working" => true,
              "regex" => ['^[\u{2800}-\u{28FF}] ']
            },
            {
              "id" => "transcript_viewer",

              "state" => "unknown",

              "priority" => 1000,
              "region" => "bottom_non_empty_lines(3)",

              "skip_state_update" => true,
              "contains" => ["showing detailed transcript"],
              "any" => [
                { "contains" => ["ctrl+o", "to toggle"] },
                { "contains" => ["ctrl+e", "show all"] },
                { "contains" => ["ctrl+e", "collapse"] },
                { "contains" => ["↑↓ scroll"] },
                { "contains" => ["? for shortcuts"] }
              ]
            },
            {
              "id" => "live_blocked_form",

              "state" => "blocked",

              "priority" => 980,
              "region" => "after_last_horizontal_rule",

              "visible_blocker" => true,
              "contains" => ["enter to select", "esc to cancel"],
              "any" => [
                { "contains" => ["tab/arrow keys to navigate"] },
                { "contains" => ["arrow keys to navigate"] },
                { "contains" => ["arrows to navigate"] },
                { "contains" => ["↑/↓ to navigate"] },
                { "contains" => ["↑↓ to navigate"] }
              ]
            },
            {
              "id" => "dynamic_workflow_prompt",

              "state" => "blocked",

              "priority" => 980,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "contains" => ["run a dynamic workflow?", "esc to cancel"]
            },
            {
              "id" => "live_prompt_box",

              "state" => "idle",

              "priority" => 950,
              "region" => "prompt_box_body",

              "visible_idle" => true,
              "line_regex" => ['^\s*❯'],
              "not" => [
                { "contains" => ["enter to select"] },
                { "contains" => ["esc to cancel"] },
                { "contains" => ["tab/arrow keys"] },
                { "contains" => ["arrow keys to navigate"] },
                { "contains" => ["↑/↓ to navigate"] }
              ]
            },
            {
              "id" => "model_picker_menu",

              "state" => "unknown",

              "priority" => 900,
              "region" => "whole_recent",

              "skip_state_update" => true,
              "contains" => ["select model", "enter to set as default", "esc to cancel"],
              "not" => [
                { "contains" => ["do you want to proceed?"] },
                { "contains" => ["enter to select"] }
              ]
            },
            {
              "id" => "bash_permission_prompt",

              "state" => "blocked",

              "priority" => 850,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "contains" => ["do you want to proceed?"],
              "any" => [
                { "contains" => ["bash command"] },
                { "contains" => ["bash("] },
                { "contains" => ["contains expansion"] },
                { "contains" => ["tab to amend"] },
                { "contains" => ["ctrl+e to explain"] }
              ],
              "all" => [
                {
                  "any" => [
                    { "line_regex" => ['(?i)^\s*❯?\s*yes\b'] },
                    { "line_regex" => ['(?i)^\s*1\.\s*yes\b'] },
                    { "line_regex" => ['(?i)^\s*2\.\s*no\b'] }
                  ]
                }
              ]
            },
            {
              "id" => "generic_permission_prompt",

              "state" => "blocked",

              "priority" => 840,
              "region" => "after_last_horizontal_rule",

              "visible_blocker" => true,
              "contains" => ["do you want to proceed?", "esc to cancel"],
              "all" => [
                {
                  "any" => [
                    { "line_regex" => ['(?i)^\s*❯?\s*1\.\s*yes\b'] },
                    { "line_regex" => ['(?i)^\s*2\.\s*yes\b'] },
                    { "line_regex" => ['(?i)^\s*2\.\s*no\b'] },
                    { "line_regex" => ['(?i)^\s*3\.\s*no\b'] }
                  ]
                }
              ]
            },
            {
              "id" => "legacy_no_prompt_blocker",

              "state" => "blocked",

              "priority" => 300,
              "region" => "whole_recent",
              "any" => [
                {
                  "contains" => ["do you want to"],
                  "any" => [{ "contains" => ["yes"] }, { "contains" => ["❯"] }]
                },
                {
                  "contains" => ["would you like to"],
                  "any" => [{ "contains" => ["yes"] }, { "contains" => ["❯"] }]
                },
                { "contains" => ["waiting for permission"] },
                { "contains" => ["do you want to allow this connection?"] },
                { "contains" => ["tab to amend"] },
                { "contains" => ["ctrl+e to explain"] },
                { "contains" => ["do you want to proceed?", "esc to cancel"] },
                { "contains" => ["review your answers"] },
                { "contains" => ["skip interview and plan immediately"] }
              ],
              "not" => [
                { "regex" => ['(?m)^\s*❯\s*$'] }
              ]
            },
            {
              "id" => "osc_title_idle",

              "state" => "idle",

              "priority" => 250,
              "region" => "osc_title",

              "visible_idle" => true,
              "regex" => ['^\u{2733} ']
            },
            {
              "id" => "osc_progress_idle",

              "state" => "idle",

              "priority" => 250,
              "region" => "osc_progress",
              "regex" => ['^4;0']
            }
          ]
        },

        "pi" => {
          "id" => "pi",
          "rules" => [
            {
              "id" => "osc_progress_working",

              "state" => "working",

              "priority" => 1100,
              "region" => "osc_progress",

              "visible_working" => true,
              "regex" => ['^9;4']
            },
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*[❯›>]\s*$'] }]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["trust this project"] },
                { "contains" => ["allow this action?"] },
                { "contains" => ["do you want to proceed?"] },
                { "contains" => ["approve?", "(y/n)"] }
              ]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*❯\s*$'] },
                { "line_regex" => ['^\s*>\s*$'] },
                { "line_regex" => ['^\s*›\s*$'] }
              ]
            }
          ]
        },

        "codex" => {
          "id" => "codex",
          "rules" => [
            {
              "id" => "osc_title_working",

              "state" => "working",

              "priority" => 1100,
              "region" => "osc_title",

              "visible_working" => true,
              "regex" => ['^[\u{2800}-\u{28FF}] ']
            },
            {
              "id" => "status_working",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "any" => [
                { "line_regex" => ['^• Working'] },
                { "contains" => ["esc to interrupt"] },
                { "line_regex" => ['^[■•]\s.*\d+s'] }
              ]
            },
            {
              "id" => "sandbox_executing",

              "state" => "working",

              "priority" => 950,
              "region" => "whole_recent",

              "visible_working" => true,
              "contains" => ["executing"],
              "not" => [{ "line_regex" => ['^\s*›\s*$'] }]
            },
            {
              "id" => "applying_changes",

              "state" => "working",

              "priority" => 940,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*›\s*$'] }]
            },
            {
              "id" => "approval_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["approve?", "(y/n)"] },
                { "contains" => ["allow?", "(y/n)"] },
                { "contains" => ["apply changes?"] }
              ]
            },
            {
              "id" => "full_auto_prompt",

              "state" => "blocked",

              "priority" => 890,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "contains" => ["run in full-auto mode?"]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "line_regex" => ['^\s*›\s*$']
            },
            {
              "id" => "completed_block",

              "state" => "idle",

              "priority" => 400,
              "region" => "bottom_non_empty_lines(5)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^✓\s'] },
                { "line_regex" => ['^✗\s'] }
              ],
              "not" => [
                {
                  "any" => [
                    { "line_regex" => ['^• Working'] },
                    { "contains" => ["esc to interrupt"] },
                    { "line_regex" => ['[⠀-⠿]'] }
                  ]
                }
              ]
            }
          ]
        },

        "gemini" => {
          "id" => "gemini",
          "rules" => [
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*[❯>]\s*$'] }]
            },
            {
              "id" => "tool_execution",

              "state" => "working",

              "priority" => 950,
              "region" => "whole_recent",

              "visible_working" => true,
              "any" => [
                {
                  "line_regex" => ['^✦\s'],
                  "not" => [{ "line_regex" => ['^\s*[❯>]\s*$'] }]
                }
              ]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["yes, allow once"] },
                { "contains" => ["yes, allow always"] },
                { "contains" => ["no, suggest changes"] },
                { "contains" => ["allow this action?"] },
                { "contains" => ["do you want to run"] }
              ]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*❯\s*$'] },
                { "line_regex" => ['^\s*>\s*$'] }
              ]
            }
          ]
        },

        "cursor" => {
          "id" => "cursor",
          "aliases" => ["cursor-agent"],
          "rules" => [
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*[❯>]\s*$'] }]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["approve?"] },
                { "contains" => ["allow this action?"] },
                { "contains" => ["do you want to proceed?"] },
                { "contains" => ["(y)es", "(n)o"] }
              ]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*>\s*$'] },
                { "line_regex" => ['^\s*❯\s*$'] }
              ]
            }
          ]
        },

        "devin" => {
          "id" => "devin",
          "aliases" => ["devin-cli"],
          "rules" => [
            {
              "id" => "running_tools",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "contains" => ["running tools"]
            },
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 950,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*[#>$]\s*$'] }]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["allow once"] },
                { "contains" => ["allow for session"] },
                { "contains" => ["allow for project"] },
                { "contains" => ["allow globally"] },
                { "contains" => ["approve?"] },
                { "contains" => ["do you want to proceed?"] }
              ]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*#\s*$'] },
                { "line_regex" => ['^\s*>\s*$'] }
              ]
            }
          ]
        },

        "amp" => {
          "id" => "amp",
          "aliases" => ["amp-local"],
          "rules" => [
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 1000,
              "region" => "whole_recent",

              "visible_working" => true,
              "line_regex" => ['[⠀-⠿]'],
              "not" => [{ "line_regex" => ['^\s*[❯>$]\s*$'] }]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "contains" => ["awaiting approval"] },
                { "contains" => ["approve?"] },
                { "contains" => ["allow?"] },
                { "contains" => ["do you want to proceed?"] },
                { "contains" => ["(y/n)"] }
              ]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*[❯>$]\s*$'] }
              ]
            }
          ]
        },

        "kiro" => {
          "id" => "kiro",
          "aliases" => ["kiro-cli"],
          "rules" => [
            {
              "id" => "title_pending_approval",

              "state" => "blocked",

              "priority" => 1100,
              "region" => "osc_title",

              "visible_blocker" => true,
              "contains" => ["pending approval"]
            },
            {
              "id" => "title_streaming",

              "state" => "working",

              "priority" => 1050,
              "region" => "osc_title",

              "visible_working" => true,
              "contains" => ["streaming"]
            },
            {
              "id" => "title_error",

              "state" => "blocked",

              "priority" => 1000,
              "region" => "osc_title",

              "visible_blocker" => true,
              "contains" => ["error"]
            },
            {
              "id" => "awaiting_approval",

              "state" => "blocked",

              "priority" => 950,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "line_regex" => ['⏸'] },
                { "contains" => ["awaiting approval"] }
              ]
            },
            {
              "id" => "permission_prompt",

              "state" => "blocked",

              "priority" => 900,
              "region" => "whole_recent",

              "visible_blocker" => true,
              "any" => [
                { "all" => [{ "contains" => ["yes"] }, { "contains" => ["trust"] }, { "contains" => ["no"] }] },
                { "contains" => ["approve?"] },
                { "contains" => ["do you want to proceed?"] }
              ]
            },
            {
              "id" => "spinner_working",

              "state" => "working",

              "priority" => 800,
              "region" => "whole_recent",

              "visible_working" => true,
              "any" => [
                { "line_regex" => ['[⠀-⠿]'] },
                { "contains" => ["thinking..."] }
              ],
              "not" => [{ "line_regex" => ['^\s*[❯>$]\s*$'] }]
            },
            {
              "id" => "idle_prompt",

              "state" => "idle",

              "priority" => 500,
              "region" => "bottom_non_empty_lines(3)",

              "visible_idle" => true,
              "any" => [
                { "line_regex" => ['^\s*[❯>$]\s*$'] }
              ]
            }
          ]
        }
      }.freeze
    end
  end
end

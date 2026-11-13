let mcpToolsJSON = #"""
[
  {
    "name": "show_card",
    "description": "Show a card on the pixel board in the notch of the Mac. Each action has a label and exactly one of: url (opens in the browser on the Mac), run (name of an action from the hub config, with optional args), reply. A card with the same key replaces the previous one.",
    "inputSchema": {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "type": "object",
      "properties": {
        "key": {
          "type": "string",
          "minLength": 1
        },
        "title": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "text": {
          "type": "string",
          "maxLength": 600
        },
        "sprite": {
          "anyOf": [
            {
              "type": "string",
              "minLength": 1
            },
            {
              "type": "object",
              "properties": {
                "palette": {
                  "type": "object",
                  "propertyNames": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 1
                  },
                  "additionalProperties": {
                    "type": "string",
                    "pattern": "^#[0-9a-fA-F]{6}$"
                  }
                },
                "frames": {
                  "minItems": 1,
                  "type": "array",
                  "items": {
                    "minItems": 1,
                    "type": "array",
                    "items": {
                      "type": "string"
                    }
                  }
                },
                "fps": {
                  "default": 4,
                  "type": "number",
                  "exclusiveMinimum": 0,
                  "maximum": 30
                }
              },
              "required": [
                "palette",
                "frames"
              ],
              "additionalProperties": false
            }
          ]
        },
        "actions": {
          "default": [],
          "maxItems": 4,
          "type": "array",
          "items": {
            "anyOf": [
              {
                "type": "object",
                "properties": {
                  "label": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 20
                  },
                  "url": {
                    "type": "string",
                    "format": "uri"
                  }
                },
                "required": [
                  "label",
                  "url"
                ],
                "additionalProperties": false
              },
              {
                "type": "object",
                "properties": {
                  "label": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 20
                  },
                  "run": {
                    "type": "string",
                    "minLength": 1
                  },
                  "args": {
                    "type": "array",
                    "items": {
                      "type": "string"
                    }
                  }
                },
                "required": [
                  "label",
                  "run"
                ],
                "additionalProperties": false
              },
              {
                "type": "object",
                "properties": {
                  "label": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 20
                  },
                  "reply": {
                    "type": "string",
                    "minLength": 1
                  }
                },
                "required": [
                  "label",
                  "reply"
                ],
                "additionalProperties": false
              }
            ]
          }
        }
      },
      "required": [
        "title"
      ]
    },
    "execution": {
      "taskSupport": "forbidden"
    }
  },
  {
    "name": "set_status",
    "description": "Set the mood of the character on the board and a short line next to it. Non-idle moods return to idle after ttlSeconds.",
    "inputSchema": {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "type": "object",
      "properties": {
        "mood": {
          "type": "string",
          "enum": [
            "idle",
            "thinking",
            "waiting",
            "done",
            "error"
          ]
        },
        "text": {
          "type": "string",
          "maxLength": 80
        },
        "ttlSeconds": {
          "default": 1800,
          "type": "number",
          "exclusiveMinimum": 0
        }
      },
      "required": [
        "mood"
      ]
    },
    "execution": {
      "taskSupport": "forbidden"
    }
  },
  {
    "name": "ask",
    "description": "Ask a question on the board and wait for a click. Returns the chosen option, or reports that nobody answered.",
    "inputSchema": {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "type": "object",
      "properties": {
        "question": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "details": {
          "type": "string",
          "maxLength": 600
        },
        "options": {
          "minItems": 1,
          "maxItems": 4,
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 20
          }
        },
        "timeoutSeconds": {
          "default": 300,
          "type": "number",
          "exclusiveMinimum": 0
        }
      },
      "required": [
        "question",
        "options"
      ]
    },
    "execution": {
      "taskSupport": "forbidden"
    }
  },
  {
    "name": "remove_card",
    "description": "Remove a card from the board.",
    "inputSchema": {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "type": "object",
      "properties": {
        "id": {
          "type": "string"
        }
      },
      "required": [
        "id"
      ]
    },
    "execution": {
      "taskSupport": "forbidden"
    }
  },
  {
    "name": "list_cards",
    "description": "List the cards currently on the board.",
    "inputSchema": {
      "type": "object",
      "properties": {}
    },
    "execution": {
      "taskSupport": "forbidden"
    }
  }
]
"""#

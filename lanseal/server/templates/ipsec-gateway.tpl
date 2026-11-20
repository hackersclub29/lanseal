{
  "subject": {"commonName": {{ toJson .Subject.CommonName }}},
  "sans": {{ toJson .SANs }},
  "keyUsage": ["digitalSignature", "keyEncipherment"],
  "extKeyUsage": ["serverAuth"],
  "unknownExtKeyUsage": ["1.3.6.1.5.5.8.2.2"]
}

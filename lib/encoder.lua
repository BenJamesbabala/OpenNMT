local model_utils = require 'lib.utils.model_utils'
local table_utils = require 'lib.utils.table_utils'
require 'lib.sequencer'

--[[ Encoder is a unidirectional Sequencer used for the source language.]]
local Encoder, Sequencer = torch.class('Encoder', 'Sequencer')

--[[ Constructor takes global `args` and optional `network`.]]
function Encoder:__init(args, network)
  Sequencer.__init(self, 'enc', args, network)
  self.mask_padding = args.mask_padding or false

  -- Preallocate context vector.
  self.context_proto = torch.zeros(args.max_batch_size, args.max_sent_length, args.rnn_size)

  if args.training then
    -- Preallocate output gradients. (Forward pass allocationed is in base class).
    self.grad_out_proto = {}
    for _ = 1, args.num_layers do
      table.insert(self.grad_out_proto, torch.zeros(args.max_batch_size, args.rnn_size))
      table.insert(self.grad_out_proto, torch.zeros(args.max_batch_size, args.rnn_size))
    end
  end
end

--[[ Call to change the `batch_size`. ]]
function Encoder:resize_proto(batch_size)
  Sequencer.resize_proto(self, batch_size)
  self.context_proto:resize(batch_size, self.context_proto:size(2), self.context_proto:size(3))
end

--[[ Compute the context representation of an input.

  TODO: Change `batch` to `input`.

  Parameters:
  * `batch` - a struct as defined data.lua.

  Returns:
  1. last hidden states
  2. context matrix H
--]]
function Encoder:forward(batch)

  local final_states

  -- Make initial states c_0, h_0.
  local states = model_utils.reset_state(self.states_proto, batch.size)

  -- Preallocated output matrix.
  local context = self.context_proto[{{1, batch.size}, {1, batch.source_length}}]

  if self.mask_padding and not batch.source_input_pad_left then
    final_states = table_utils.clone(states)
  end
  if not self.eval_mode then
    self.inputs = {}
  end

  -- Act like nn.Sequential and call each clone in a feed-forward
  -- fashion.
  for t = 1, batch.source_length do

    -- Construct "inputs". Prev states come first then source.
    local inputs = {}
    table_utils.append(inputs, states)
    table.insert(inputs, batch.source_input[t])

    if not self.eval_mode then
      -- Remember inputs for the backward pass.
      self.inputs[t] = inputs
    end

    -- TODO: Shouldn't this just be self:net?
    states = Sequencer.net(self, t):forward(inputs)


    -- Special case padding.
    if self.mask_padding then
      for b = 1, batch.size do
        if batch.source_input_pad_left and t <= batch.source_length - batch.source_size[b] then
          for j = 1, #states do
            states[j][b]:zero()
          end
        elseif not batch.source_input_pad_left and t == batch.source_size[b] then
          for j = 1, #states do
            final_states[j][b]:copy(states[j][b])
          end
        end
      end
    end

    -- Copy output (h^L_t = states[#states]) to context.
    context[{{}, t}]:copy(states[#states])
  end

  if final_states == nil then
    final_states = states
  end

  return final_states, context
end

--[[ Backward pass (only called during training)
  TODO: change this to (input, gradOutput) as in nngraph.

  Parameters:
  * `batch` - must be same as for forward
  * `grad_states_output`
  * `grad_context_output` - gradient of loss
      wrt last states and context.
--]]
function Encoder:backward(batch, grad_states_output, grad_context_output)

  local grad_states_input = model_utils.copy_state(self.grad_out_proto, grad_states_output, batch.size)

  for t = batch.source_length, 1, -1 do
    -- Add context gradients to last hidden states gradients.
    grad_states_input[#grad_states_input]:add(grad_context_output[{{}, t}])

    local grad_input = Sequencer.net(self, t):backward(self.inputs[t], grad_states_input)

    -- Prepare next encoder output gradients.
    for i = 1, #grad_states_input do
      grad_states_input[i]:copy(grad_input[i])
    end
  end

  Sequencer.backward_word_vecs(self)
end

function Encoder:convert(f)
  Sequencer.convert(self, f)
  self.context_proto = f(self.context_proto)
end

return Encoder

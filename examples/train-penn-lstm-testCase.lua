-- Options
local opt = lapp [[
Train an LSTM to fit the Penn Treebank dataset.

Options:
   --nEpochs        (default 20)      nb of epochs
   --bpropLength    (default 20)      max backprop steps
   --batchSize      (default 20)      batch size
   --wordDim        (default 200)     word vector dimensionality
   --hiddens        (default 200)     nb of hidden units
   --capEpoch       (default -1)      cap epoch to given number of steps (for debugging)
   --reportEvery    (default 200)     report training accuracy every N steps
   --learningRate   (default 20)      learning rate
   --maxGradNorm    (default .25)     cap gradient norm
   --paramRange     (default .1)      initial parameter range
   --dropout        (default 0)       dropout probability on hidden states
   --type           (default float)   tensor type: cuda | float | double
]]

-- CUDA?
if opt.type == 'cuda' then
   require 'cutorch'
   require 'cunn'
   cutorch.manualSeed(1)
end

-- Libs
local d = require 'autograd'
local util = require 'autograd.util'
local model = require 'autograd.model'
local _ = require 'moses'
local tablex = require('pl.tablex')

d.optimize(true)

-- Seed
torch.manualSeed(1)

-- Load in PENN Treebank dataset
local trainData, valData, testData, dict = require('./get-penn.lua')()
local nTokens = #dict.id2word

-- Move data to CUDA
if opt.type == 'cuda' then
   trainData = trainData:cuda()
   testData = testData:cuda()
   valData = valData:cuda()
elseif opt.type == 'double' then
   trainData = trainData:double()
   testData = testData:double()
   valData = valData:double()
end

print('Loaded datasets: ', {
   train = trainData,
   validation = valData,
   test = testData,
   nTokens = nTokens,
})

-- Define LSTM layers:
local lstm1,params = model.RecurrentLSTMNetwork({
   inputFeatures = opt.wordDim,
   hiddenFeatures = opt.hiddens,
   outputType = 'all',
})
local lstm2 = model.RecurrentLSTMNetwork({
   inputFeatures = opt.hiddens,
   hiddenFeatures = opt.hiddens,
   outputType = 'all',
}, params)

-- Dropout
local regularize = util.dropout

-- Shortcuts
local nElements = opt.batchSize*opt.bpropLength
local nClasses = #dict.id2word

-- Use built-in nn modules:
local lsm = d.nn.LogSoftMax()
local lossf = d.nn.ClassNLLCriterion()

-- Complete trainable function:
local f = function(params, x, y, prevState, dropout)
   -- N elements:
   local batchSize = torch.size(x, 1)
   local bpropLength = torch.size(x, 2)
   local nElements = batchSize * bpropLength

   -- Select word vectors
   x = util.lookup(params.words.W, x)

   -- Encode all inputs through LSTM layers:
   local h1,newState1 = lstm1(params[1], regularize(x,dropout), prevState[1])
   local h2,newState2 = lstm2(params[2], regularize(h1,dropout), prevState[2])

   -- Flatten batch + temporal
   local h2f = torch.view(h2, nElements, opt.hiddens)
   local yf = torch.view(y, nElements)

   -- Linear classifier:
   local h3 = regularize(h2f,dropout) * params[3].W + torch.expand(params[3].b, nElements, nClasses)

   -- Lsm
   local yhat = lsm(h3)

   -- Loss:
   local loss = lossf(yhat, yf)

   -- Return avergage loss
   return loss, {newState1, newState2}
end

-- Linear classifier params:
table.insert(params, {
   W = torch.Tensor(opt.hiddens, #dict.id2word),
   b = torch.Tensor(1, #dict.id2word),
})

-- Init weights + cast:
for i,weights in ipairs(params) do
   for k,weight in pairs(weights) do
      if opt.type == 'cuda' then
         weights[k] = weights[k]:cuda()
      elseif opt.type == 'double' then
         weights[k] = weights[k]:double()
      else
         weights[k] = weights[k]:float()
      end
      weights[k]:uniform(-opt.paramRange, opt.paramRange)
   end
end

-- Word dictionary to train:
local words
if opt.type == 'cuda' then
   words = torch.CudaTensor(nTokens, opt.wordDim)
elseif opt.type == 'double' then
   words = torch.DoubleTensor(nTokens, opt.wordDim)
else
   words = torch.FloatTensor(nTokens, opt.wordDim)
end
words:uniform(-opt.paramRange, opt.paramRange)
params.words = {W = words}

-- Reformat training data for batches:
local epochLength = math.floor(trainData:size(1) / opt.batchSize)
trainData = trainData:narrow(1,1,epochLength*opt.batchSize):view(opt.batchSize, epochLength)

-- Optional cap:
if tonumber(opt.capEpoch) > 0 then
   epochLength = opt.capEpoch
end

-- Train it
local lr = opt.learningRate
local reportEvery = opt.reportEvery
local valPerplexity = math.huge

local df =  d(f, { optimize = false })

for epoch = 1,opt.nEpochs do
   -- Train:
   print('\nTraining Epoch #'..epoch)
   local lstmState = {} -- clear LSTM state at each new epoch
   local grads,loss
   for i = 1,10,opt.bpropLength do

      -- Next sequence:
      local x = trainData:narrow(2,i,opt.bpropLength):contiguous()
      local y = trainData:narrow(2,i+1,opt.bpropLength):contiguous()

      -- Grads:
      grads,loss,lstmState = df(params, x, y, lstmState, opt.dropout)

   end

end
